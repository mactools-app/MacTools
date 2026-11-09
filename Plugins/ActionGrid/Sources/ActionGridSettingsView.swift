import AppKit
import MacToolsPluginKit
import SwiftUI

enum ActionGridDragPayload {
    private static let prefix = "mactools-action-grid:"

    static func encode(_ entryID: UUID) -> String {
        "\(prefix)\(entryID.uuidString)"
    }

    static func decode(_ payload: String?) -> UUID? {
        guard let payload, payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}

struct ActionGridEntryMoveAvailability: Equatable {
    let canMoveUp: Bool
    let canMoveDown: Bool

    init(slot: Int, maximumEntryCount: Int) {
        canMoveUp = slot > 0
        canMoveDown = slot < maximumEntryCount - 1
    }
}

enum ActionGridAccessibilityMoveAction: Equatable {
    case up
    case down
}

struct ActionGridAccessibilityMoveActions: Equatable {
    let actions: [ActionGridAccessibilityMoveAction]

    init(availability: ActionGridEntryMoveAvailability) {
        actions = [
            availability.canMoveUp ? .up : nil,
            availability.canMoveDown ? .down : nil,
        ].compactMap { $0 }
    }
}

struct ActionGridActionPickerAccessibility: Equatable {
    let confirmationValue: String?

    init(isSafe: Bool, confirmationRequiredText: String) {
        confirmationValue = isSafe ? nil : confirmationRequiredText
    }
}

private struct ActionGridConfirmationAccessibilityModifier: ViewModifier {
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

private struct ActionGridConditionalAccessibilityActionModifier: ViewModifier {
    let isEnabled: Bool
    let name: String
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: name, action)
        } else {
            content
        }
    }
}

private struct ActionGridKeyboardMoveModifier: ViewModifier {
    let availability: ActionGridEntryMoveAvailability
    let moveUp: () -> Void
    let moveDown: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(phases: .down) { press in
                guard press.modifiers == [.command, .option] else { return .ignored }
                switch press.key {
                case .upArrow where availability.canMoveUp:
                    moveUp()
                    return .handled
                case .downArrow where availability.canMoveDown:
                    moveDown()
                    return .handled
                default:
                    return .ignored
                }
            }
    }
}

struct ActionGridSettingsView: View {
    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @State private var confirmingReset = false
    @State private var folderPath: [UUID] = []
    @State private var editorRequest: ActionGridEditorRequest?
    @State private var dropTargetSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            gridEditor
            if let error = store.loadError {
                Label(
                    plugin.localizedFormat("无法读取已保存的网格：%@", error),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(.red)
                    .font(PluginSettingsTheme.Typography.rowDescription)
            }
        }
        .alert(plugin.localized("重置操作网格？"), isPresented: $confirmingReset) {
            Button(plugin.localized("重置"), role: .destructive) {
                if store.reset(to: plugin.suggestedReferences()) {
                    plugin.notifyMutation()
                }
            }
            Button(plugin.localized("取消"), role: .cancel) {}
        } message: {
            Text(plugin.localized("这会替换当前条目，并使用一组安全的建议操作。"))
        }
        .sheet(item: $editorRequest, onDismiss: { editorRequest = nil }) { request in
            Group {
                switch request {
                case let .action(actionRequest):
                    ActionGridActionEditorSheet(
                        plugin: plugin,
                        store: store,
                        folderID: currentFolderID,
                        request: actionRequest,
                        onDismiss: dismissEditor
                    )
                case let .folder(folderRequest):
                    ActionGridFolderEditorSheet(
                        plugin: plugin,
                        store: store,
                        folderID: currentFolderID,
                        request: folderRequest,
                        onDismiss: dismissEditor
                    )
                }
            }
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
        }
        .onChange(of: folderPath) { _, _ in
            dropTargetSlot = nil
        }
        .onDisappear {
            dropTargetSlot = nil
        }
    }

    private var gridEditor: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.sectionHeaderContent) {
            HStack(spacing: PluginSettingsTheme.Spacing.controlCluster) {
                if !folderPath.isEmpty {
                    Button {
                        folderPath.removeLast()
                    } label: {
                        Label(plugin.localized("返回"), systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Label(currentTitle, systemImage: currentFolderID == nil ? "square.grid.3x3" : "folder.fill")
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    guard let slot = store.firstAvailableSlot(in: currentFolderID) else { return }
                    presentEditor(.action(ActionGridActionEditorRequest(
                        entryID: nil,
                        targetSlot: slot,
                        allowsFolder: folderPath.count < ActionGridStore.maximumFolderDepth
                    )))
                } label: {
                    Label(plugin.localized("添加"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    store.loadError != nil
                        || currentEntries.count >= ActionGridStore.maximumEntryCount
                )

                Button(plugin.localized("重置")) { confirmingReset = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(currentFolderID != nil)
            }

            LazyVGrid(columns: gridColumns, spacing: 10) {
                ForEach(0 ..< ActionGridStore.maximumEntryCount, id: \.self) { index in
                    if let entry = store.entry(at: index, in: currentFolderID) {
                        entryCell(entry, index: index)
                    } else {
                        emptyCell(index: index)
                    }
                }
            }
            .padding(12)
            .pluginSettingsCardBackground(.standard)
            .disabled(store.loadError != nil)

            if let dropTargetSlot {
                Label(
                    dropStatus(for: dropTargetSlot),
                    systemImage: dropStatusImage(for: dropTargetSlot)
                )
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                Text(plugin.localized("拖动单元格可重新排序。选择操作可原位编辑；选择文件夹可打开下一级网格。"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func entryCell(_ entry: ActionGridEntry, index: Int) -> some View {
        let moveAvailability = ActionGridEntryMoveAvailability(
            slot: index,
            maximumEntryCount: ActionGridStore.maximumEntryCount
        )
        let accessibilityMoveActions = ActionGridAccessibilityMoveActions(
            availability: moveAvailability
        )
        let item = entry.folder == nil ? plugin.item(for: entry.reference) : nil
        let title = entry.customTitle
            ?? item?.title
            ?? plugin.localized("不可用操作")
        let image = entry.folder?.systemImage
            ?? item?.systemImage
            ?? "questionmark.square.dashed"
        let subtitle = entry.folder != nil
            ? plugin.localized("文件夹")
            : (item?.ownerTitle ?? plugin.localized("提供者缺失"))

        return Button {
            if entry.folder != nil {
                folderPath.append(entry.id)
            } else {
                presentEditor(.action(ActionGridActionEditorRequest(
                    entryID: entry.id,
                    targetSlot: entry.slot,
                    allowsFolder: false
                )))
            }
        } label: {
            VStack(spacing: 7) {
                Image(systemName: PluginSystemImage.resolvedName(image))
                    .font(.title2)
                Text(title)
                    .font(PluginSettingsTheme.Typography.rowTitle)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .contentShape(Rectangle())
            .background(
                PluginSettingsTheme.Surface.raisedControl,
                in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
            )
            .overlay {
                dropTargetOverlay(index: index, destinationTitle: title)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(dropTargetSlot == index ? 0.97 : 1)
        .draggable(dragPayload(for: entry.id)) {
            dragPreview(title: title, image: image, isFolder: entry.folder != nil)
        }
        .dropDestination(for: String.self) { payloads, _ in
            guard let entryID = entryID(from: payloads.first) else { return false }
            return performDrop(entryID, at: index)
        } isTargeted: { isTargeted in
            updateDropTarget(index: index, isTargeted: isTargeted)
        }
        .animation(.easeOut(duration: 0.14), value: dropTargetSlot)
        .modifier(ActionGridKeyboardMoveModifier(
            availability: moveAvailability,
            moveUp: { moveEntry(at: index, offset: -1) },
            moveDown: { moveEntry(at: index, offset: 1) }
        ))
        .contextMenu {
            Button(plugin.localized("上移")) {
                moveEntry(at: index, offset: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(!moveAvailability.canMoveUp)

            Button(plugin.localized("下移")) {
                moveEntry(at: index, offset: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(!moveAvailability.canMoveDown)

            Divider()
            if entry.folder != nil {
                Button(plugin.localized("重命名")) {
                    presentEditor(.folder(ActionGridFolderEditorRequest(entryID: entry.id)))
                }
                Divider()
            } else if item?.canOpenOwner == true {
                Button(plugin.localized("设置")) {
                    _ = plugin.openOwner(for: entry.reference)
                }
                Divider()
            }
            Button(plugin.localized("删除"), role: .destructive) {
                if store.remove(id: entry.id) { plugin.notifyMutation() }
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(entry.folder != nil ? plugin.localized("打开文件夹") : plugin.localized("编辑操作"))
        .modifier(ActionGridConditionalAccessibilityActionModifier(
            isEnabled: accessibilityMoveActions.actions.contains(.up),
            name: plugin.localized("上移"),
            action: { moveEntry(at: index, offset: -1) }
        ))
        .modifier(ActionGridConditionalAccessibilityActionModifier(
            isEnabled: accessibilityMoveActions.actions.contains(.down),
            name: plugin.localized("下移"),
            action: { moveEntry(at: index, offset: 1) }
        ))
    }

    private func emptyCell(index: Int) -> some View {
        Button {
            presentEditor(.action(ActionGridActionEditorRequest(
                entryID: nil,
                targetSlot: index,
                allowsFolder: folderPath.count < ActionGridStore.maximumFolderDepth
            )))
        } label: {
            VStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.title2)
                Text(plugin.localized("添加"))
                    .font(PluginSettingsTheme.Typography.rowTitle)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .background(
                PluginSettingsTheme.Palette.recessedControlBackground,
                in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
            )
            .overlay {
                dropTargetOverlay(index: index, destinationTitle: nil)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(dropTargetSlot == index ? 0.97 : 1)
        .dropDestination(for: String.self) { payloads, _ in
            guard let entryID = entryID(from: payloads.first) else { return false }
            return performDrop(entryID, at: index)
        } isTargeted: { isTargeted in
            updateDropTarget(index: index, isTargeted: isTargeted)
        }
        .animation(.easeOut(duration: 0.14), value: dropTargetSlot)
        .accessibilityLabel(plugin.localizedFormat("添加第 %d 个单元格", index + 1))
    }

    private func dragPayload(for entryID: UUID) -> String {
        ActionGridDragPayload.encode(entryID)
    }

    private func entryID(from payload: String?) -> UUID? {
        ActionGridDragPayload.decode(payload)
    }

    private func updateDropTarget(index: Int, isTargeted: Bool) {
        if isTargeted {
            dropTargetSlot = index
        } else if dropTargetSlot == index {
            dropTargetSlot = nil
        }
    }

    private func performDrop(_ entryID: UUID, at slot: Int) -> Bool {
        guard let source = currentEntries.first(where: { $0.id == entryID }) else {
            return false
        }
        guard source.slot != slot else { return true }
        let didMove = withAnimation(.easeInOut(duration: 0.2)) {
            store.move(entryID: entryID, toIndex: slot, in: currentFolderID)
        }
        guard didMove else {
            return false
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        plugin.notifyMutation()
        return true
    }

    @ViewBuilder
    private func dropTargetOverlay(index: Int, destinationTitle: String?) -> some View {
        if dropTargetSlot == index {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                .fill(Color.accentColor.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                        .stroke(Color.accentColor, lineWidth: 2.5)
                }
                .overlay {
                    VStack(spacing: 5) {
                        Image(systemName: destinationTitle == nil
                            ? "arrow.down.to.line.compact"
                            : "arrow.triangle.swap")
                            .font(.title2.weight(.semibold))
                        Text(destinationTitle == nil
                            ? plugin.localized("移动到这里")
                            : plugin.localized("交换位置"))
                            .font(PluginSettingsTheme.Typography.statusBadge)
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .allowsHitTesting(false)
        }
    }

    private func dragPreview(title: String, image: String, isFolder: Bool) -> some View {
        VStack(spacing: 7) {
            Image(systemName: PluginSystemImage.resolvedName(image))
                .font(.title2)
            Text(title)
                .font(PluginSettingsTheme.Typography.rowTitle)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(isFolder ? plugin.localized("文件夹") : plugin.localized("操作"))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
        }
        .frame(width: 168, height: 104)
        .background(
            PluginSettingsTheme.Surface.raisedControl,
            in: RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PluginSettingsTheme.Radius.card)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 14, y: 8)
        .opacity(0.94)
    }

    private func dropStatus(for targetSlot: Int) -> String {
        if let destination = store.entry(at: targetSlot, in: currentFolderID) {
            let destinationTitle = destination.customTitle
                ?? plugin.item(for: destination.reference)?.title
                ?? plugin.localized("不可用操作")
            return plugin.localizedFormat("松开以与“%@”交换位置", destinationTitle)
        }
        return plugin.localizedFormat("松开以移动到第 %d 个单元格", targetSlot + 1)
    }

    private func dropStatusImage(for targetSlot: Int) -> String {
        return store.entry(at: targetSlot, in: currentFolderID) == nil
            ? "arrow.down.to.line.compact"
            : "arrow.triangle.swap"
    }

    private func moveEntry(at index: Int, offset: Int) {
        guard let entry = store.entry(at: index, in: currentFolderID),
              store.move(entryID: entry.id, toIndex: index + offset, in: currentFolderID) else {
            return
        }
        plugin.notifyMutation()
    }

    private var currentFolderID: UUID? { folderPath.last }

    private var currentEntries: [ActionGridEntry] {
        store.entries(in: currentFolderID)
    }

    private var currentTitle: String {
        guard let currentFolderID else { return plugin.localized("操作网格") }
        return store.folderEntry(id: currentFolderID)?.customTitle ?? plugin.localized("文件夹")
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    }

    private func presentEditor(_ request: ActionGridEditorRequest) {
        editorRequest = nil
        DispatchQueue.main.async {
            editorRequest = request
        }
    }

    private func dismissEditor() {
        editorRequest = nil
    }
}

private struct ActionGridActionEditorRequest: Identifiable {
    let id = UUID()
    let entryID: UUID?
    let targetSlot: Int?
    let allowsFolder: Bool
}

private struct ActionGridFolderEditorRequest: Identifiable {
    let id = UUID()
    let entryID: UUID?
}

private enum ActionGridEditorRequest: Identifiable {
    case action(ActionGridActionEditorRequest)
    case folder(ActionGridFolderEditorRequest)

    var id: UUID {
        switch self {
        case let .action(request): request.id
        case let .folder(request): request.id
        }
    }
}

private enum ActionGridAddKind: String, CaseIterable, Identifiable {
    case action
    case folder

    var id: String { rawValue }
}

enum ActionGridActionSelectionPolicy {
    static func contains(
        _ reference: ActionReference?,
        in items: [ActionSurfaceCatalogItem]
    ) -> Bool {
        guard let reference else { return false }
        return items.contains { $0.reference == reference }
    }
}

struct ActionGridActionPickerPresentation: Equatable {
    let title: String
    let detail: String
    let badge: String?

    init(
        item: ActionSurfaceCatalogItem,
        toggleLabel: String,
        nextActionDetail: String
    ) {
        if item.presentationState != nil {
            title = item.ownerTitle
            detail = nextActionDetail
            badge = toggleLabel
        } else {
            title = item.title
            detail = item.ownerTitle
            badge = nil
        }
    }
}

private struct ActionGridActionEditorSheet: View {
    private enum Field: Hashable {
        case search
        case title
    }

    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    let folderID: UUID?
    let request: ActionGridActionEditorRequest
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedReference: ActionReference?
    @State private var customTitle = ""
    @State private var addKind: ActionGridAddKind = .action
    @FocusState private var focusedField: Field?

    init(
        plugin: ActionGridPlugin,
        store: ActionGridStore,
        folderID: UUID?,
        request: ActionGridActionEditorRequest,
        onDismiss: @escaping () -> Void
    ) {
        self.plugin = plugin
        self.store = store
        self.folderID = folderID
        self.request = request
        self.onDismiss = onDismiss
        let entry = request.entryID.flatMap(store.folderEntry(id:))
        _selectedReference = State(initialValue: entry?.reference)
        _customTitle = State(initialValue: entry?.customTitle ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editorTitle)
                .font(PluginSettingsTheme.Typography.pageTitle)

            if request.entryID == nil, request.allowsFolder {
                Picker("", selection: $addKind) {
                    Text(plugin.localized("添加操作")).tag(ActionGridAddKind.action)
                    Text(plugin.localized("新建文件夹")).tag(ActionGridAddKind.folder)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            if addKind == .action || request.entryID != nil {
                TextField(plugin.localized("搜索操作"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .search)

                TextField(titleFieldPlaceholder, text: $customTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)

                List(filteredItems, selection: $selectedReference) { item in
                    let presentation = pickerPresentation(for: item)
                    let accessibility = ActionGridActionPickerAccessibility(
                        isSafe: item.isSafe,
                        confirmationRequiredText: plugin.localized("执行前需要确认。")
                    )
                    HStack(spacing: 10) {
                        Image(systemName: PluginSystemImage.resolvedName(item.systemImage))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(presentation.title)
                                if let badge = presentation.badge {
                                    Text(badge)
                                        .font(PluginSettingsTheme.Typography.statusBadge)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                            }
                            Text(presentation.detail)
                                .font(PluginSettingsTheme.Typography.rowDescription)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !item.isSafe {
                            Image(systemName: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                        }
                    }
                    .modifier(ActionGridConfirmationAccessibilityModifier(
                        value: accessibility.confirmationValue
                    ))
                    .tag(item.reference)
                }
                .frame(minHeight: 300)
            } else {
                TextField(titleFieldPlaceholder, text: $customTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .title)

                ContentUnavailableView(
                    plugin.localized("新建文件夹"),
                    systemImage: "folder.badge.plus"
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }

            HStack {
                if let entryID = request.entryID {
                    Button(plugin.localized("删除"), role: .destructive) {
                        if store.remove(id: entryID) { plugin.notifyMutation() }
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(plugin.localized("取消"), action: onDismiss)
                    .buttonStyle(.bordered)
                Button(plugin.localized("保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(minWidth: 520, minHeight: 500)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = addKind == .action || request.entryID != nil ? .search : .title
            }
        }
        .onChange(of: addKind) { _, kind in
            focusedField = kind == .action ? .search : .title
        }
        .onChange(of: query) { _, _ in
            clearHiddenSelection()
        }
    }

    private var filteredItems: [ActionSurfaceCatalogItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return plugin.catalogItems(excluding: request.entryID, in: folderID).filter { item in
            let presentation = pickerPresentation(for: item)
            return query.isEmpty || [
                item.title,
                item.subtitle,
                item.ownerTitle,
                presentation.title,
                presentation.detail,
                presentation.badge,
            ]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func pickerPresentation(
        for item: ActionSurfaceCatalogItem
    ) -> ActionGridActionPickerPresentation {
        ActionGridActionPickerPresentation(
            item: item,
            toggleLabel: plugin.localized("切换"),
            nextActionDetail: plugin.localizedFormat("下次执行：%@", item.title)
        )
    }

    private var editorTitle: String {
        if request.entryID != nil { return plugin.localized("编辑操作") }
        return addKind == .folder
            ? plugin.localized("新建文件夹")
            : plugin.localized("添加操作")
    }

    private var titleFieldPlaceholder: String {
        addKind == .folder && request.entryID == nil
            ? plugin.localized("文件夹名称")
            : plugin.localized("自定义名称（可选）")
    }

    private var canSave: Bool {
        if request.entryID != nil || addKind == .action {
            return ActionGridActionSelectionPolicy.contains(
                selectedReference,
                in: filteredItems
            )
        }
        return !customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearHiddenSelection() {
        guard selectedReference != nil,
              !ActionGridActionSelectionPolicy.contains(
                  selectedReference,
                  in: filteredItems
              ) else {
            return
        }
        self.selectedReference = nil
    }

    private func save() {
        let saved: Bool
        if let entryID = request.entryID {
            guard let selectedReference else { return }
            saved = store.replace(
                id: entryID,
                reference: selectedReference,
                customTitle: customTitle
            )
        } else if addKind == .folder {
            saved = store.addFolder(
                title: customTitle,
                in: folderID,
                at: request.targetSlot
            )
        } else {
            guard let selectedReference else { return }
            saved = store.add(
                reference: selectedReference,
                customTitle: customTitle,
                in: folderID,
                at: request.targetSlot
            )
        }
        if saved {
            plugin.notifyMutation()
            onDismiss()
        }
    }
}

private struct ActionGridFolderEditorSheet: View {
    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    let folderID: UUID?
    let request: ActionGridFolderEditorRequest
    let onDismiss: () -> Void

    @State private var title: String

    init(
        plugin: ActionGridPlugin,
        store: ActionGridStore,
        folderID: UUID?,
        request: ActionGridFolderEditorRequest,
        onDismiss: @escaping () -> Void
    ) {
        self.plugin = plugin
        self.store = store
        self.folderID = folderID
        self.request = request
        self.onDismiss = onDismiss
        _title = State(
            initialValue: request.entryID.flatMap(store.folderEntry(id:))?.customTitle ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.entryID == nil ? plugin.localized("新建文件夹") : plugin.localized("重命名文件夹"))
                .font(PluginSettingsTheme.Typography.pageTitle)
            TextField(plugin.localized("文件夹名称"), text: $title)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let entryID = request.entryID {
                    Button(plugin.localized("删除"), role: .destructive) {
                        if store.remove(id: entryID) { plugin.notifyMutation() }
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button(plugin.localized("取消"), action: onDismiss)
                    .buttonStyle(.bordered)
                Button(plugin.localized("保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(PluginSettingsTheme.Spacing.pagePadding)
        .frame(width: 420)
    }

    private func save() {
        let saved: Bool
        if let entryID = request.entryID {
            saved = store.setCustomTitle(id: entryID, title: title)
        } else {
            saved = store.addFolder(title: title, in: folderID)
        }
        if saved {
            plugin.notifyMutation()
            onDismiss()
        }
    }
}

struct ActionGridEntryRow: View {
    let plugin: ActionGridPlugin
    @ObservedObject var store: ActionGridStore
    let entry: ActionGridEntry

    var body: some View {
        let item = plugin.item(for: entry.reference)
        let title = entry.customTitle ?? item?.title ?? plugin.localized("不可用操作")
        let owner = item?.ownerTitle ?? plugin.localized("提供者缺失")
        let availability = item.map {
            $0.availability.isAvailable
                ? plugin.localized("可用")
                : ($0.availability.reason ?? plugin.localized("不可用"))
        } ?? plugin.localized("重新安装后会自动恢复")
        let accessibility = ActionGridEntryAccessibility(
            title: title,
            owner: owner,
            availability: availability,
            copy: plugin.accessibilityCopy
        )
        HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
            Image(systemName: PluginSystemImage.resolvedName(
                item?.systemImage ?? PluginSystemImage.fallbackName
            ))
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PluginSettingsTheme.Typography.emphasizedRowTitle)
                Text("\(owner) · \(availability)")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(item?.availability.isAvailable == true ? Color.secondary : Color.red)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibility.summaryLabel)
            ActionGridEntryControlsView(
                settingsAction: item?.canOpenOwner == true ? {
                    _ = plugin.openOwner(for: entry.reference)
                } : nil,
                replacementOptions: plugin.catalogItems(excluding: entry.id).map {
                    ActionGridReplacementOption(title: $0.title, reference: $0.reference)
                },
                replaceAction: { replacement in
                    if store.replace(id: entry.id, reference: replacement) {
                        plugin.notifyMutation()
                    }
                },
                removeAction: {
                    if store.remove(id: entry.id) { plugin.notifyMutation() }
                },
                accessibility: accessibility,
                identifierPrefix: "mactools.action-grid.entry.\(entry.id.uuidString)"
            )
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ActionGridReplacementOption: Equatable {
    let title: String
    let reference: ActionReference
}

struct ActionGridEntryControlsView: NSViewRepresentable {
    let settingsAction: (() -> Void)?
    let replacementOptions: [ActionGridReplacementOption]
    let replaceAction: (ActionReference) -> Void
    let removeAction: () -> Void
    let accessibility: ActionGridEntryAccessibility
    let identifierPrefix: String

    func makeNSView(context: Context) -> NativeView {
        NativeView()
    }

    func updateNSView(_ nsView: NativeView, context: Context) {
        nsView.update(
            settingsAction: settingsAction,
            replacementOptions: replacementOptions,
            replaceAction: replaceAction,
            removeAction: removeAction,
            accessibility: accessibility,
            identifierPrefix: identifierPrefix
        )
    }

    final class NativeView: NSStackView {
        let settingsButton: NSButton
        let replacementButton: NSPopUpButton
        let removeButton: NSButton
        var settingsAction: (() -> Void)?
        var replaceAction: ((ActionReference) -> Void)?
        var removeAction: (() -> Void)?
        var replacementOptions: [ActionGridReplacementOption] = []

        override init(frame frameRect: NSRect) {
            settingsButton = NSButton(title: "", target: nil, action: nil)
            replacementButton = NSPopUpButton(frame: .zero, pullsDown: true)
            removeButton = NSButton(
                image: NSImage(
                    systemSymbolName: "trash",
                    accessibilityDescription: nil
                ) ?? NSImage(),
                target: nil,
                action: nil
            )
            super.init(frame: frameRect)

            settingsButton.target = self
            settingsButton.action = #selector(openSettings)
            settingsButton.bezelStyle = .rounded
            settingsButton.controlSize = .small

            replacementButton.bezelStyle = .rounded
            replacementButton.controlSize = .small

            removeButton.target = self
            removeButton.action = #selector(remove)
            removeButton.bezelStyle = .inline
            removeButton.isBordered = false
            removeButton.controlSize = .small
            removeButton.contentTintColor = .systemRed

            setViews([settingsButton, replacementButton, removeButton], in: .leading)
            orientation = .horizontal
            alignment = .centerY
            spacing = PluginSettingsTheme.Spacing.rowContentControl
            setHuggingPriority(.required, for: .horizontal)
            setAccessibilityElement(false)
        }

        convenience init() {
            self.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(
            settingsAction: (() -> Void)?,
            replacementOptions: [ActionGridReplacementOption],
            replaceAction: @escaping (ActionReference) -> Void,
            removeAction: @escaping () -> Void,
            accessibility: ActionGridEntryAccessibility,
            identifierPrefix: String
        ) {
            self.settingsAction = settingsAction
            self.replaceAction = replaceAction
            self.removeAction = removeAction
            self.replacementOptions = replacementOptions

            settingsButton.isHidden = settingsAction == nil
            settingsButton.title = accessibility.copy.settingsButtonTitle
            configure(
                settingsButton,
                role: .button,
                label: accessibility.settingsLabel,
                help: accessibility.copy.settingsHelp,
                identifier: "\(identifierPrefix).settings"
            )
            configure(
                replacementButton,
                role: .menuButton,
                label: accessibility.replaceLabel,
                help: accessibility.copy.replaceHelp,
                identifier: "\(identifierPrefix).replace"
            )
            configure(
                removeButton,
                role: .button,
                label: accessibility.removeLabel,
                help: accessibility.copy.removeHelp,
                identifier: "\(identifierPrefix).remove"
            )

            let menu = NSMenu()
            menu.addItem(
                withTitle: accessibility.copy.replacementMenuTitle,
                action: nil,
                keyEquivalent: ""
            )
            for (index, option) in replacementOptions.enumerated() {
                let item = NSMenuItem(
                    title: option.title,
                    action: #selector(replace(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
            replacementButton.menu = menu
            replacementButton.isEnabled = !replacementOptions.isEmpty
            setAccessibilityChildren(
                [settingsButton, replacementButton, removeButton].filter { !$0.isHidden }
            )
        }

        private func configure(
            _ element: NSView,
            role: NSAccessibility.Role,
            label: String,
            help: String,
            identifier: String
        ) {
            element.setAccessibilityElement(true)
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel(label)
            element.setAccessibilityHelp(help)
            element.setAccessibilityIdentifier(identifier)
        }

        @objc func openSettings() {
            settingsAction?()
        }

        @objc func replace(_ sender: NSMenuItem) {
            guard replacementOptions.indices.contains(sender.tag) else { return }
            replaceAction?(replacementOptions[sender.tag].reference)
        }

        @objc func remove() {
            removeAction?()
        }
    }
}

struct ActionGridEntryAccessibility: Equatable {
    let title: String
    let owner: String
    let availability: String
    let copy: ActionGridAccessibilityCopy

    init(
        title: String,
        owner: String,
        availability: String,
        copy: ActionGridAccessibilityCopy = .source
    ) {
        self.title = title
        self.owner = owner
        self.availability = availability
        self.copy = copy
    }

    var summaryLabel: String {
        String(format: copy.summaryFormat, title, owner, availability)
    }
    var settingsLabel: String { String(format: copy.settingsLabelFormat, title) }
    var replaceLabel: String { String(format: copy.replaceLabelFormat, title) }
    var removeLabel: String { String(format: copy.removeLabelFormat, title) }
}

struct ActionGridAccessibilityCopy: Equatable {
    let summaryFormat: String
    let settingsLabelFormat: String
    let replaceLabelFormat: String
    let removeLabelFormat: String
    let settingsButtonTitle: String
    let replacementMenuTitle: String
    let settingsHelp: String
    let replaceHelp: String
    let removeHelp: String

    static let source = ActionGridAccessibilityCopy(
        summaryFormat: "%@，%@，%@",
        settingsLabelFormat: "设置“%@”",
        replaceLabelFormat: "替换“%@”",
        removeLabelFormat: "移除“%@”",
        settingsButtonTitle: "设置",
        replacementMenuTitle: "替换",
        settingsHelp: "打开操作提供者设置",
        replaceHelp: "选择其他操作替换此条目",
        removeHelp: "从操作网格移除此条目"
    )
}
