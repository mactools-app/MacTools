import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

private enum SidecarSettingsColumnWidth {
    static let picker: CGFloat = 144
    static let shortcutRecorder = PluginSettingsTheme.Size.shortcutRecorderWidth
    static let shortcutActionButton: CGFloat = 22
    static let shortcutActions: CGFloat = 50
}

private struct SidecarShortcutConflictWarning: Identifiable {
    let id = UUID()
    let itemID: String
    let binding: ShortcutBinding
}

struct SidecarSettingsView: View {
    @ObservedObject var store: SidecarPreferencesStore
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let liveDevices: [SidecarDevice]
    let localization: PluginLocalization
    let settingsContext: PluginSettingsContext
    let onRefresh: () -> Void
    let onUpdate: () -> Void

    private var displayedDevices: [SidecarDevicePreference] {
        let liveDevicesByID = Dictionary(uniqueKeysWithValues: liveDevices.map { ($0.id, $0) })
        return store.devices.filter {
            liveDevicesByID[$0.id] != nil || $0.hasCustomConfiguration
        }
        .sorted { lhs, rhs in
            let lhsRank = SidecarDeviceOrdering.rank(for: liveDevicesByID[lhs.id]?.connectionState)
            let rhsRank = SidecarDeviceOrdering.rank(for: liveDevicesByID[rhs.id]?.connectionState)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            let lhsPriority = store.priorityIndex(for: lhs.id)
            let rhsPriority = store.priorityIndex(for: rhs.id)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        savedDevicesSection
            .environment(\.locale, locale)
            .environment(
                \.layoutDirection,
                locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            )
    }

    private var savedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
                Text(localization.string(
                    "settings.devices.description",
                    defaultValue: "设备离线时仍会保留它的设置和快捷键。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

                Label(
                    localization.string(
                        "panel.wired.warning",
                        defaultValue: "请求仅通过有线连接，不请求 Wi-Fi 回退"
                    ),
                    systemImage: "cable.connector"
                )
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)

                Text(localization.string(
                    "settings.priority.description",
                    defaultValue: "拖动可用显示器，设置“连接第一个可用显示器”使用的优先级。"
                ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)

            if displayedDevices.isEmpty {
                ContentUnavailableView(
                    localization.string("settings.devices.empty.title", defaultValue: "未发现 Sidecar 设备"),
                    systemImage: "display",
                    description: Text(localization.string(
                        "settings.devices.empty.description",
                        defaultValue: "请让设备靠近并解锁，然后刷新。"
                    ))
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, PluginSettingsTheme.Spacing.pagePadding)
            } else {
                deviceSettingsCard
            }
        }
    }

    private var deviceSettingsCard: some View {
        VStack(spacing: 0) {
            SidecarDeviceSettingsTable(
                items: displayedDeviceRows,
                makeRow: { item, isLast in
                    AnyView(deviceSettingsRow(for: item, isLast: isLast))
                },
                onMoveBefore: { draggedDeviceID, targetDeviceID in
                    if store.move(deviceID: draggedDeviceID, before: targetDeviceID) {
                        onUpdate()
                    }
                }
            )
            .frame(height: SidecarDeviceSettingsTable.preferredHeight(for: displayedDeviceRows.count))
        }
        .frame(maxWidth: .infinity)
    }

    private func state(for preference: SidecarDevicePreference) -> SidecarDeviceSettingsState {
        guard let device = liveDevices.first(where: { $0.id == preference.id }) else {
            return .unavailable
        }
        switch device.connectionState {
        case .connected: return .connected
        case .disconnected: return .available
        case .unknown: return .unknown
        }
    }

    private var displayedDeviceRows: [SidecarDeviceSettingsTable.Item] {
        displayedDevices.map { preference in
            SidecarDeviceSettingsTable.Item(preference: preference, state: state(for: preference))
        }
    }

    private func deviceSettingsRow(
        for item: SidecarDeviceSettingsTable.Item,
        isLast: Bool
    ) -> some View {
        VStack(spacing: 0) {
            SidecarDeviceSettingsRow(
                preference: item.preference,
                state: item.state,
                localization: localization,
                settingsContext: settingsContext,
                onTransportChange: { transport in
                    if store.updateTransport(transport, for: item.preference.id) {
                        onUpdate()
                    }
                },
                onShortcutActionChange: { action in
                    if store.updateShortcutAction(action, for: item.preference.id) {
                        onUpdate()
                    }
                },
                isReorderable: item.state == .available
            )

            if !isLast {
                PluginSettingsListDivider()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private enum SidecarDeviceSettingsState: Equatable {
    case connected
    case available
    case unknown
    case unavailable
}

private struct SidecarDeviceSettingsTable: NSViewRepresentable {
    struct Item: Identifiable, Equatable {
        let preference: SidecarDevicePreference
        let state: SidecarDeviceSettingsState

        var id: String { preference.id }
    }

    static let rowHeight: CGFloat = 116
    private static let dragType = NSPasteboard.PasteboardType("com.ggbond.mactools.sidecar-device")

    let items: [Item]
    let makeRow: (Item, Bool) -> AnyView
    let onMoveBefore: (String, String?) -> Void

    static func preferredHeight(for itemCount: Int) -> CGFloat {
        CGFloat(itemCount) * rowHeight
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SidecarNonScrollingTableScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let tableView = PluginSettingsReorderTableView(dragType: Self.dragType)
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidecar-device"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.canBeginDrag = { [weak coordinator = context.coordinator] rowIndexes in
            coordinator?.canBeginDrag(rows: rowIndexes) ?? false
        }
        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        syncLayout(in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        syncLayout(in: scrollView, coordinator: context.coordinator)
    }

    private func syncLayout(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard let tableView = coordinator.tableView, !coordinator.isDragging else { return }

        let contentWidth = max(scrollView.contentSize.width, 1)
        let signature = Signature(items: items, contentWidth: contentWidth)
        guard coordinator.lastSignature != signature else { return }

        coordinator.lastSignature = signature
        tableView.reloadData()
        tableView.noteNumberOfRowsChanged()
        tableView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: Self.preferredHeight(for: items.count)
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SidecarDeviceSettingsTable
        weak var tableView: NSTableView?
        fileprivate var lastSignature: Signature?
        private(set) var isDragging = false

        init(parent: SidecarDeviceSettingsTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            SidecarDeviceSettingsTable.rowHeight
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("SidecarDeviceSettingsCell")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SidecarDeviceSettingsCellView)
                ?? SidecarDeviceSettingsCellView(frame: .zero)
            view.identifier = identifier
            view.configure(rootView: parent.makeRow(parent.items[row], row == parent.items.indices.last))
            return view
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.items[row].state == .available else { return nil }
            let item = NSPasteboardItem()
            item.setString(parent.items[row].id, forType: SidecarDeviceSettingsTable.dragType)
            return item
        }

        func canBeginDrag(rows: IndexSet) -> Bool {
            !rows.isEmpty && rows.allSatisfy { row in
                parent.items.indices.contains(row) && parent.items[row].state == .available
            }
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            isDragging = true
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .none
        }

        func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {
            draggingInfo.enumerateDraggingItems(
                options: [],
                for: tableView,
                classes: [NSPasteboardItem.self],
                searchOptions: [:]
            ) { draggingItem, _, _ in
                guard
                    let pasteboardItem = draggingItem.item as? NSPasteboardItem,
                    let deviceID = pasteboardItem.string(forType: SidecarDeviceSettingsTable.dragType),
                    let row = self.parent.items.firstIndex(where: { $0.id == deviceID }),
                    let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
                    let preview = cellView.dragPreviewImage()
                else {
                    return
                }

                let frame = NSRect(origin: draggingItem.draggingFrame.origin, size: preview.size)
                draggingItem.setDraggingFrame(frame, contents: preview)
            }
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            lastSignature = nil
            tableView.reloadData()
        }

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard
                info.draggingPasteboard.availableType(from: [SidecarDeviceSettingsTable.dragType]) != nil,
                let firstAvailableRow = parent.items.firstIndex(where: { $0.state == .available }),
                let lastAvailableRow = parent.items.lastIndex(where: { $0.state == .available })
            else {
                return []
            }

            let targetRow = min(max(row, firstAvailableRow), lastAvailableRow + 1)
            tableView.setDropRow(targetRow, dropOperation: .above)
            return .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let draggedDeviceID = info.draggingPasteboard.string(forType: SidecarDeviceSettingsTable.dragType) else {
                return false
            }

            let targetRow = min(max(row, 0), parent.items.count)
            let targetDeviceID = targetRow < parent.items.count ? parent.items[targetRow].id : nil
            parent.onMoveBefore(draggedDeviceID, targetDeviceID)
            return true
        }
    }

    fileprivate struct Signature: Equatable {
        let items: [Item]
        let contentWidth: CGFloat

        init(items: [Item], contentWidth: CGFloat) {
            self.items = items
            self.contentWidth = contentWidth.rounded(.toNearestOrAwayFromZero)
        }
    }
}

private final class SidecarDeviceSettingsCellView: NSTableCellView {
    private let hostedView = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(hostedView)
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(rootView: AnyView) {
        hostedView.rootView = AnyView(SidecarDeviceSettingsCellRootView(content: rootView))
    }
}

private struct SidecarDeviceSettingsCellRootView: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: AnyView

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .environment(\.locale, locale)
            .environment(
                \.layoutDirection,
                locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            )
    }
}

private final class SidecarNonScrollingTableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private extension NSView {
    func dragPreviewImage() -> NSImage? {
        let bounds = bounds.integral
        guard !bounds.isEmpty,
              let representation = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return nil
        }

        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}

private struct SidecarDeviceSettingsRow: View {
    @Environment(\.locale) private var locale
    let preference: SidecarDevicePreference
    let state: SidecarDeviceSettingsState
    let localization: PluginLocalization
    let settingsContext: PluginSettingsContext
    let onTransportChange: (SidecarConnectionTransport) -> Void
    let onShortcutActionChange: (SidecarShortcutAction) -> Void
    let isReorderable: Bool
    @State private var pendingShortcutConflictWarning: SidecarShortcutConflictWarning?

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 0) {
            connectionLine
            innerDivider
            shortcutLine
        }
        .pluginSettingsListRowPadding(interactive: true)
        .alert(item: $pendingShortcutConflictWarning) { warning in
            Alert(
                title: Text(localization.format(
                    "settings.shortcut.commonConflictWarning.title",
                    defaultValue: "仍要使用“%@”？",
                    ShortcutFormatter.displayString(for: warning.binding)
                )),
                message: Text(localization.string(
                    "settings.shortcut.commonConflictWarning.message",
                    defaultValue: "这是全局快捷键，可能覆盖其他应用的常用操作。"
                )),
                primaryButton: .default(
                    Text(localization.string(
                        "settings.shortcut.commonConflictWarning.confirm",
                        defaultValue: "仍要使用"
                    )),
                    action: {
                        _ = settingsContext.recordShortcut(warning.binding, for: warning.itemID)
                    }
                ),
                secondaryButton: .cancel(
                    Text(localization.string(
                        "settings.shortcut.commonConflictWarning.cancel",
                        defaultValue: "取消"
                    ))
                )
            )
        }
    }

    private var connectionLine: some View {
        ViewThatFits(in: .horizontal) {
            connectionLineContent(showsLabel: true)
            connectionLineContent(showsLabel: false)
        }
    }

    private func connectionLineContent(showsLabel: Bool) -> some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            deviceIdentity

            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                if showsLabel {
                    Label(
                        localization.string(
                            "settings.group.connectionPolicy",
                            defaultValue: "连接策略"
                        ),
                        systemImage: "cable.connector"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(localization.string(
                        "settings.group.connectionPolicy",
                        defaultValue: "连接策略"
                    ))
                } else {
                    Image(systemName: "cable.connector")
                        .font(PluginSettingsTheme.Typography.rowIcon)
                        .foregroundStyle(.secondary)
                        .frame(width: PluginSettingsTheme.Size.rowIcon)
                        .help(localization.string(
                            "settings.group.connectionPolicy",
                            defaultValue: "连接策略"
                        ))
                }

                transportPicker
                    .frame(width: SidecarSettingsColumnWidth.picker)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var innerDivider: some View {
        PluginSettingsListDivider()
            .padding(.leading, shortcutContentInset)
            .padding(.vertical, PluginSettingsTheme.Spacing.rowTitleDescription + 1)
            .opacity(0.55)
    }

    private var shortcutLine: some View {
        ViewThatFits(in: .horizontal) {
            shortcutLineContent(showsActionLabel: true)
            shortcutLineContent(showsActionLabel: false)
        }
    }

    private func shortcutLineContent(showsActionLabel: Bool) -> some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Color.clear
                .frame(width: 14)

            Spacer(minLength: 0)

            HStack(
                alignment: .center,
                spacing: PluginSettingsTheme.Spacing.rowContentControl * 2
            ) {
                HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    Label(
                        localization.string("settings.column.shortcut", defaultValue: "快捷键"),
                        systemImage: "keyboard"
                    )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(localization.string("settings.column.shortcut", defaultValue: "快捷键"))

                    shortcutControl
                        .frame(
                            width: SidecarSettingsColumnWidth.shortcutRecorder
                                + SidecarSettingsColumnWidth.shortcutActions
                                + PluginSettingsTheme.Spacing.controlCluster,
                            alignment: .leading
                        )
                }

                HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    if showsActionLabel {
                        Text(localization.string("settings.column.action", defaultValue: "操作"))
                            .font(PluginSettingsTheme.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help(localization.string("settings.column.action", defaultValue: "操作"))
                    }

                    shortcutActionPicker
                        .frame(width: SidecarSettingsColumnWidth.picker)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var shortcutControl: some View {
        if let shortcutItem {
            HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.controlCluster) {
                PluginShortcutRecorder(
                    title: shortcutItem.title,
                    displayText: shortcutItem.bindingText,
                    minWidth: SidecarSettingsColumnWidth.shortcutRecorder,
                    onRecord: { binding in
                        recordShortcut(binding, for: shortcutItem.id)
                    },
                    onBeginRecording: {
                        settingsContext.beginShortcutRecording(for: shortcutItem.id)
                    }
                )
                .frame(width: SidecarSettingsColumnWidth.shortcutRecorder)

                HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                    if let errorMessage = shortcutItem.errorMessage {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: SidecarSettingsColumnWidth.shortcutActionButton)
                            .help(errorMessage)
                    }

                    if shortcutItem.canClear {
                        Button {
                            settingsContext.clearShortcut(for: shortcutItem.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(PluginSettingsTheme.Typography.rowIcon)
                                .frame(
                                    width: SidecarSettingsColumnWidth.shortcutActionButton,
                                    height: SidecarSettingsColumnWidth.shortcutActionButton
                                )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(localization.string("settings.shortcut.clear", defaultValue: "清除快捷键"))
                    }
                }
                .frame(width: SidecarSettingsColumnWidth.shortcutActions, alignment: .leading)
            }
        } else {
            PluginShortcutRecorderField(
                displayText: "",
                isRecording: false,
                minWidth: SidecarSettingsColumnWidth.shortcutRecorder
            )
            .frame(width: SidecarSettingsColumnWidth.shortcutRecorder)
            .disabled(true)
        }
    }

    private func recordShortcut(
        _ binding: ShortcutBinding,
        for itemID: String
    ) -> PluginShortcutRecordingResult {
        if CommonApplicationShortcutBindings.requiresConflictWarning(for: binding) {
            pendingShortcutConflictWarning = SidecarShortcutConflictWarning(
                itemID: itemID,
                binding: binding
            )
            return .accepted
        }

        return settingsContext.recordShortcut(binding, for: itemID)
    }

    private var shortcutItem: ShortcutSettingsItem? {
        settingsContext.shortcutItem(definitionID: "device.\(preference.id)")
    }

    private var shortcutContentInset: CGFloat {
        14
            + PluginSettingsTheme.Spacing.rowContentControl
            + PluginSettingsTheme.Size.rowIcon
            + PluginSettingsTheme.Spacing.rowContentControl
    }

    private var deviceIdentity: some View {
        HStack(alignment: .center, spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Group {
                if isReorderable {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14)

            Image(systemName: statusIcon)
                .font(PluginSettingsTheme.Typography.sectionTitle)
                .foregroundStyle(statusColor)
                .frame(width: PluginSettingsTheme.Size.rowIcon)

            VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                Text(preference.name)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                    .lineLimit(1)

                Text(statusText)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var transportPicker: some View {
        Picker(String(), selection: Binding(
                get: { preference.transport },
                set: { transport in
                    onTransportChange(transport)
                }
        )) {
            Text(localization.string("settings.transport.automatic", defaultValue: "自动"))
                .tag(SidecarConnectionTransport.automatic)
            Text(localization.string("settings.transport.wiredOnly", defaultValue: "仅有线"))
                .tag(SidecarConnectionTransport.wiredOnly)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(localization.string("settings.column.connection", defaultValue: "连接方式"))
        .help(localization.string("settings.transport.help", defaultValue: "连接时使用的传输方式"))
    }

    private var shortcutActionPicker: some View {
        Picker(String(), selection: Binding(
                get: { preference.shortcutAction },
                set: { action in
                    onShortcutActionChange(action)
                }
        )) {
            Text(localization.string("settings.shortcutAction.toggle", defaultValue: "切换"))
                .tag(SidecarShortcutAction.toggle)
            Text(localization.string("panel.action.connect", defaultValue: "连接"))
                .tag(SidecarShortcutAction.connect)
            Text(localization.string("panel.action.disconnect", defaultValue: "断开连接"))
                .tag(SidecarShortcutAction.disconnect)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(localization.string("settings.column.shortcutAction", defaultValue: "快捷键操作"))
        .help(localization.string("settings.shortcutAction.help", defaultValue: "此设备快捷键执行的操作"))
    }

    private var statusIcon: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .available: "circle"
        case .unknown: "questionmark.circle"
        case .unavailable: "wifi.slash"
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .available: .secondary
        case .unknown: .orange
        case .unavailable: .secondary
        }
    }

    private var statusText: String {
        switch state {
        case .connected:
            localization.string("settings.deviceStatus.connected", defaultValue: "已连接")
        case .available:
            localization.string("settings.deviceStatus.available", defaultValue: "可连接")
        case .unknown:
            localization.string("settings.deviceStatus.unknown", defaultValue: "连接状态未知")
        case .unavailable:
            localization.string("settings.deviceStatus.unavailable", defaultValue: "当前不可用")
        }
    }
}
