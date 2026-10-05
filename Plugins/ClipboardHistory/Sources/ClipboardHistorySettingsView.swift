import AppKit
import MacToolsPluginKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardHistorySettingsContentSection: Hashable {
    case history
    case queue
    case snippets
    case advanced
    case data
}

@MainActor
private final class ClipboardHistorySettingsPresentationModel: ObservableObject {
    struct Snapshot: Equatable {
        var usage: ClipboardHistoryUsage
        var historyItemCount: Int
        var savedItemCount: Int
        var snippetCount: Int
        var historyErrorMessage: String?
        var storageError: ClipboardHistoryStoreError?
        var savedErrorMessage: String?
        var savedFatalErrorMessage: String?
        var isHistoryLoaded: Bool
        var isClearingHistory: Bool
        var isCollectionOperational: Bool
        var canResetUnreadableHistory: Bool
    }

    @Published private(set) var snapshot: Snapshot

    init(
        controller: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController
    ) {
        snapshot = Self.makeSnapshot(
            controller: controller,
            savedLibraryController: savedLibraryController
        )
    }

    func refreshHistoryItems(_ items: [ClipboardHistoryItem]) {
        let historyItems = items.filter(\.isInHistory)
        var next = snapshot
        next.usage = ClipboardHistoryUsage(items: historyItems)
        next.historyItemCount = historyItems.count
        next.savedItemCount = items.lazy.filter(\.isSaved).count
        publish(next)
    }

    func refreshHistoryStatus(_ controller: ClipboardHistoryController) {
        var next = snapshot
        next.historyErrorMessage = controller.errorMessage
        next.storageError = controller.storageError
        next.isHistoryLoaded = controller.isLoaded
        next.isClearingHistory = controller.isClearingHistory
        next.isCollectionOperational = controller.isCollectionOperational
        next.canResetUnreadableHistory = controller.canResetUnreadablePersistentHistory
        publish(next)
    }

    func refreshSavedLibrary(_ controller: ClipboardSavedLibraryController) {
        var next = snapshot
        next.snippetCount = controller.items.count
        next.savedErrorMessage = controller.errorMessage
        next.savedFatalErrorMessage = controller.fatalErrorMessage
        publish(next)
    }

    func refreshSavedLibraryItems(_ items: [ClipboardSavedItem]) {
        var next = snapshot
        next.snippetCount = items.count
        publish(next)
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
    }

    private static func makeSnapshot(
        controller: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController
    ) -> Snapshot {
        let historyItems = controller.items.filter(\.isInHistory)
        return Snapshot(
            usage: ClipboardHistoryUsage(items: historyItems),
            historyItemCount: historyItems.count,
            savedItemCount: controller.items.lazy.filter(\.isSaved).count,
            snippetCount: savedLibraryController.items.count,
            historyErrorMessage: controller.errorMessage,
            storageError: controller.storageError,
            savedErrorMessage: savedLibraryController.errorMessage,
            savedFatalErrorMessage: savedLibraryController.fatalErrorMessage,
            isHistoryLoaded: controller.isLoaded,
            isClearingHistory: controller.isClearingHistory,
            isCollectionOperational: controller.isCollectionOperational,
            canResetUnreadableHistory: controller.canResetUnreadablePersistentHistory
        )
    }
}

@MainActor
struct ClipboardHistorySettingsView: View {
    @Environment(\.pluginSettingsSearchTarget) private var searchTarget
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    let controller: ClipboardHistoryController
    let savedLibraryController: ClipboardSavedLibraryController
    @ObservedObject private var settings: ClipboardHistorySettingsStore
    @StateObject private var presentation: ClipboardHistorySettingsPresentationModel
    @ObservedObject private var itemShortcutStore: ClipboardItemShortcutStore
    private let localization: PluginLocalization
    private let settingsContext: PluginSettingsContext?
    private let contentSections: Set<ClipboardHistorySettingsContentSection>
    private let onManageSnippets: (() -> Void)?
    private let onRemoveItemShortcut: (UUID, ClipboardItemShortcutStore.PasteFormat) -> Void
    private let backupService: (() -> ClipboardBackupService?)?
    private let onBackupSuspend: () -> Void
    private let onBackupResume: (Bool) -> Void
    private let provisionalSavedMetadataForBackup: () -> [UUID: ClipboardHistorySavedMetadata]
    @State private var clearRequest: ClipboardHistorySettingsClearRequest?
    @State private var setupDestination: ClipboardHistorySetupDestination?
    @State private var isHistoryAdvancedExpanded = false
    @State private var isQueueAdvancedExpanded = false
    @State private var isExclusionsExpanded = false
    @State private var isWindowShortcutsExpanded = false
    @State private var isPrivateCopyShortcutsExpanded = false
    @State private var isSnippetAdvancedExpanded = false

    init(
        controller: ClipboardHistoryController,
        savedLibraryController: ClipboardSavedLibraryController,
        localization: PluginLocalization,
        settingsContext: PluginSettingsContext? = nil,
        contentSections: Set<ClipboardHistorySettingsContentSection> = [
            .history,
            .snippets,
            .queue,
            .advanced,
            .data,
        ],
        onManageSnippets: (() -> Void)? = nil,
        itemShortcutStore: ClipboardItemShortcutStore,
        onRemoveItemShortcut: @escaping (UUID, ClipboardItemShortcutStore.PasteFormat) -> Void = { _, _ in },
        backupService: (() -> ClipboardBackupService?)? = nil,
        onBackupSuspend: @escaping () -> Void = {},
        onBackupResume: @escaping (Bool) -> Void = { _ in },
        provisionalSavedMetadataForBackup: @escaping () -> [UUID: ClipboardHistorySavedMetadata] = { [:] }
    ) {
        self.controller = controller
        self.savedLibraryController = savedLibraryController
        self.localization = localization
        self.settingsContext = settingsContext
        self.contentSections = contentSections
        self.onManageSnippets = onManageSnippets
        self.itemShortcutStore = itemShortcutStore
        self.onRemoveItemShortcut = onRemoveItemShortcut
        self.backupService = backupService
        self.onBackupSuspend = onBackupSuspend
        self.onBackupResume = onBackupResume
        self.provisionalSavedMetadataForBackup = provisionalSavedMetadataForBackup
        _settings = ObservedObject(wrappedValue: controller.settings)
        _presentation = StateObject(wrappedValue: ClipboardHistorySettingsPresentationModel(
            controller: controller,
            savedLibraryController: savedLibraryController
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.section) {
            if contentSections.contains(.history) {
                historySection
            }
            if contentSections.contains(.snippets) {
                snippetsSection
            }
            if contentSections.contains(.queue) {
                sequentialPasteSection
            }
            if contentSections.contains(.advanced) {
                advancedSection
            }
            if contentSections.contains(.data) {
                dataSection
            }
        }
        .onChange(of: searchTarget, initial: true) { _, target in
            revealShortcutGroup(target)
        }
        .onReceive(controller.objectWillChange) { _ in
            refreshHistoryStatusAfterPublication()
        }
        .onReceive(controller.itemUpdates) { update in
            presentation.refreshHistoryItems(update.items)
        }
        .onReceive(savedLibraryController.objectWillChange) { _ in
            refreshSavedLibraryAfterPublication()
        }
        .onReceive(savedLibraryController.itemUpdates) { update in
            presentation.refreshSavedLibraryItems(update.items)
        }
        .onAppear {
            guard contentSections.contains(.history),
                  settingsContext != nil,
                  settings.shouldAutomaticallyPresentInitialSetup()
            else {
                return
            }
            setupDestination = .guide
        }
        .sheet(item: $setupDestination) { _ in
            if let settingsContext {
                ClipboardHistorySetupSheet(
                    controller: controller,
                    localization: localization,
                    settingsContext: settingsContext
                )
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
            }
        }
        .alert(item: $clearRequest) { request in
            switch request {
            case .all:
                Alert(
                    title: Text(localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？")),
                    message: Text(localization.string(
                        "clear.all.message",
                        defaultValue: "Clears History. Saved clips and snippets are kept. This cannot be undone."
                    ) + "\n\n" + queueRetentionNotice),
                    primaryButton: .destructive(Text(localization.string("settings.data.clearHistory", defaultValue: "Clear History"))) {
                        Task { await controller.clearAllHistory() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .savedClips:
                Alert(
                    title: Text(localization.string(
                        "settings.saved.clear.title",
                        defaultValue: "Clear Saved Clips?"
                    )),
                    message: Text(localization.string(
                        "settings.saved.clear.message",
                        defaultValue: "Removes Saved status from clips in History and permanently deletes Saved-only clips. History and snippets are kept. This cannot be undone."
                    ) + "\n\n" + queueRetentionNotice),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.saved.clear.confirm",
                        defaultValue: "Clear Saved Clips"
                    ))) {
                        Task { _ = await controller.clearAllSavedItems() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .snippets:
                Alert(
                    title: Text(localization.string(
                        "settings.snippets.clear.title",
                        defaultValue: "Delete All Snippets?"
                    )),
                    message: Text(localization.string(
                        "settings.snippets.clear.message",
                        defaultValue: "Permanently deletes all snippets and their keywords. History and Saved clips are kept. This cannot be undone."
                    ) + "\n\n" + queueRetentionNotice),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.snippets.clear.confirm",
                        defaultValue: "Delete Snippets"
                    ))) {
                        Task { _ = await savedLibraryController.clearAll() }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            case .resetUnreadable:
                Alert(
                    title: Text(localization.string(
                        "settings.storage.reset.title",
                        defaultValue: "Delete Unreadable Clipboard Data?"
                    )),
                    message: Text(localization.string(
                        "settings.storage.reset.message",
                        defaultValue: "This deletes the encrypted Clipboard database and its Keychain key. History, Saved clips, and snippets cannot be recovered."
                    )),
                    primaryButton: .destructive(Text(localization.string(
                        "settings.storage.reset.confirm",
                        defaultValue: "删除并重新开始"
                    ))) {
                        Task {
                            // Drain snippet reads and writes before the shared database/key reset.
                            // The stores also share a database coordinator, so no queued operation
                            // can recreate the database inside the reset boundary.
                            savedLibraryController.stop()
                            if await controller.resetUnreadablePersistentHistory() {
                                savedLibraryController.reloadAfterExternalDatabaseReset()
                            } else {
                                savedLibraryController.start()
                            }
                        }
                    },
                    secondaryButton: .cancel(Text(localization.string("common.cancel", defaultValue: "取消")))
                )
            }
        }
    }

    private func refreshHistoryStatusAfterPublication() {
        Task { @MainActor in
            await Task.yield()
            presentation.refreshHistoryStatus(controller)
        }
    }

    private func refreshSavedLibraryAfterPublication() {
        Task { @MainActor in
            await Task.yield()
            presentation.refreshSavedLibrary(savedLibraryController)
        }
    }

    private var queueRetentionNotice: String {
        localization.string(
            "queue.explicit.retentionNotice",
            defaultValue: "An active explicit paste queue keeps its encrypted copies until the queue finishes or is canceled."
        )
    }

    private func revealShortcutGroup(_ target: PluginSettingsSearchTarget?) {
        guard let target, target.pluginID == ClipboardHistoryPlugin.pluginID else { return }
        switch target.entryID {
        case ClipboardHistoryPlugin.ShortcutID.panelGroup
            where contentSections.contains(.advanced):
            isWindowShortcutsExpanded = true
        case ClipboardHistoryPlugin.ShortcutID.collectionGroup
            where contentSections.contains(.history):
            isHistoryAdvancedExpanded = true
        case ClipboardHistoryPlugin.ShortcutID.privacyGroup
            where contentSections.contains(.advanced):
            isPrivateCopyShortcutsExpanded = true
        case ClipboardHistoryPlugin.ShortcutID.queueGroup where contentSections.contains(.queue):
            isQueueAdvancedExpanded = true
        default:
            break
        }
    }

    @ViewBuilder
    private var itemShortcutRows: some View {
        if itemShortcutStore.assignments.isEmpty {
            PluginSettingsListDivider()
            PluginSettingsItem(
                title: localization.string("itemShortcut.settings.title", defaultValue: "Item Shortcuts"),
                description: localization.string(
                    "itemShortcut.settings.empty",
                    defaultValue: "Choose Assign Shortcut from an item's Actions menu."
                ),
                systemImage: "keyboard"
            ) { EmptyView() }
            .pluginSettingsListRowPadding(interactive: false)
        }
        ForEach(itemShortcutStore.assignments) { assignment in
            PluginSettingsListDivider()
            VStack(alignment: .leading, spacing: 4) {
                pluginShortcutRow(assignment.definitionID)
                HStack {
                    Text(assignment.expiresAt.map {
                        localization.format("settings.quickPaste.until", defaultValue: "Until %@",
                                            $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PluginRuntimeLocalization.locale)))
                    } ?? localization.string("settings.quickPaste.noExpiry", defaultValue: "Until removed"))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(localization.string("settings.quickPaste.remove", defaultValue: "Remove Shortcut")) {
                        onRemoveItemShortcut(assignment.itemID, assignment.pasteFormat)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, PluginSettingsTheme.Spacing.rowHorizontal)
            }
        }
    }

    private var historySection: some View {
        VStack(spacing: 0) {
            privacyAndStorageOverview
            PluginSettingsListDivider()
            collectionSection
            PluginSettingsListDivider()
            VStack(spacing: 0) {
                actionShortcutRow(ClipboardHistoryPlugin.ActionID.openHistory, systemImage: "clipboard")
                PluginSettingsListDivider()
                pluginShortcutRow(ClipboardHistoryPlugin.ShortcutID.pastePlainText)
                itemShortcutRows
            }
            .pluginSettingsSearchAnchor(
                pluginID: ClipboardHistoryPlugin.pluginID,
                entryID: ClipboardHistoryPlugin.ShortcutID.primaryGroup
            )
            PluginSettingsListDivider()
            ClipboardSettingsDisclosure(
                isExpanded: $isHistoryAdvancedExpanded,
                accessibilityValue: disclosureAccessibilityValue(isHistoryAdvancedExpanded),
                headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
            ) {
                VStack(spacing: 0) {
                    retentionOptions
                    PluginSettingsListDivider()
                    if let context = settingsContext {
                        ForEach(ClipboardHistoryPlugin.collectionControlActionIDs, id: \.self) { actionID in
                            if context.actionShortcutItem(actionID: actionID) != nil {
                                actionShortcutRow(actionID, systemImage: collectionControlIcon(actionID))
                                if actionID != ClipboardHistoryPlugin.collectionControlActionIDs.last {
                                    PluginSettingsListDivider()
                                }
                            }
                        }
                    }
                }
            } label: {
                PluginSettingsItem(
                    title: localization.string("settings.advanced.title", defaultValue: "Advanced"),
                    description: retentionSummary,
                    systemImage: "slider.horizontal.3"
                ) {}
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
            .pluginSettingsSearchAnchor(
                pluginID: ClipboardHistoryPlugin.pluginID,
                entryID: ClipboardHistoryPlugin.ShortcutID.collectionGroup
            )
        }
    }

    private var privacyAndStorageOverview: some View {
        PluginSettingsItem(
            title: localization.string("settings.privacyOverview.section", defaultValue: "Privacy & Storage"),
            description: localization.string(
                "settings.privacyOverview.summary",
                defaultValue: "Content is encrypted on this Mac. The key is stored in Keychain."
            ),
            systemImage: "lock.shield"
        ) {
            HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                Text(encryptedStorageStatusTitle)
                    .font(PluginSettingsTheme.Typography.statusBadge)
                    .foregroundStyle(encryptedStorageStatusColor)
                    .fixedSize()
                Button {
                    setupDestination = .guide
                } label: {
                    Text(settings.hasCompletedInitialSetup
                        ? localization.string("setup.show", defaultValue: "Setup Guide")
                        : localization.string("setup.continue", defaultValue: "Continue Setup"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .disabled(settingsContext == nil)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var snippetsSection: some View {
        VStack(spacing: 0) {
            if let errorMessage = presentation.snapshot.savedFatalErrorMessage
                ?? presentation.snapshot.savedErrorMessage {
                VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.red)
                    Text(localization.string(
                        "settings.snippets.description",
                        defaultValue: "Reusable editable templates with optional keywords, tags, and paste-time variables."
                    ))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                    HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                        Button(localization.string(
                            "settings.storage.retry",
                            defaultValue: "Retry"
                        )) {
                            savedLibraryController.retryLoading()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if presentation.snapshot.savedFatalErrorMessage != nil {
                            Button(localization.string(
                                "settings.snippets.clear",
                                defaultValue: "Delete Snippets"
                            ) + "…", role: .destructive) {
                                clearRequest = .snippets
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pluginSettingsListRowPadding(interactive: true)
                PluginSettingsListDivider()
            }

            PluginSettingsItem(
                title: localization.string("settings.snippets.library.title", defaultValue: "Snippet Library"),
                description: localization.format(
                    "settings.snippets.count", defaultValue: "%d snippets", presentation.snapshot.snippetCount
                ),
                systemImage: "text.quote"
            ) {
                Button(localization.string("settings.snippets.manage", defaultValue: "Manage Snippets")) {
                    onManageSnippets?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(onManageSnippets == nil)
            }
            .pluginSettingsListRowPadding(interactive: true)

            PluginSettingsListDivider()
            PluginSettingsItem(
                title: localization.string("settings.saved.expansion.title", defaultValue: "Expand Snippet Keywords"),
                description: localization.string(
                    "settings.saved.expansion.description",
                    defaultValue: "Replace a snippet keyword as you type. Secure text fields are ignored."
                ),
                systemImage: "text.cursor"
            ) {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Text(keywordExpansionStatusTitle)
                        .font(PluginSettingsTheme.Typography.statusBadge)
                        .foregroundStyle(keywordExpansionStatusColor)
                        .fixedSize()
                    if settings.keywordExpansionStatus == .accessibilityRequired {
                        Button(localization.string("settings.saved.expansion.allowAccess", defaultValue: "Allow Access")) {
                            _ = ClipboardHistoryAccessibilityCheck.requestTrust(prompt: true)
                            settings.refreshKeywordExpansion()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    ClipboardSettingsSwitch(
                        accessibilityLabel: localization.string("settings.saved.expansion.title", defaultValue: "Expand Snippet Keywords"),
                        isOn: $settings.isKeywordExpansionEnabled
                    )
                }
            }
            .pluginSettingsListRowPadding(interactive: true)
            if let diagnostic = keywordExpansionDiagnosticTitle {
                Text(diagnostic)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()
            }
            PluginSettingsListDivider()
            ClipboardSettingsDisclosure(
                isExpanded: $isSnippetAdvancedExpanded,
                accessibilityValue: disclosureAccessibilityValue(isSnippetAdvancedExpanded),
                headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
            ) {
                settingPickerRow(
                    title: localization.string("settings.snippets.expandedLimit.title", defaultValue: "Expanded Text Limit"),
                    description: localization.string("settings.snippets.expandedLimit.description", defaultValue: "Limits the final text after variables expand. Oversized output is rejected."),
                    systemImage: "textformat.size",
                    selection: $settings.maximumExpandedTextByteCount
                ) {
                    ForEach(ClipboardHistorySettingsStore.allowedExpandedTextByteCounts, id: \.self) { count in
                        Text(byteCountTitle(count)).tag(count)
                    }
                }
            } label: {
                PluginSettingsItem(
                    title: localization.string("settings.advanced.title", defaultValue: "Advanced"),
                    systemImage: "slider.horizontal.3"
                ) {}
            }
            .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        }
    }

    private var keywordExpansionStatusTitle: String {
        switch settings.keywordExpansionStatus {
        case .off:
            localization.string("settings.saved.expansion.status.off", defaultValue: "Off")
        case .noKeywords:
            localization.string("settings.saved.expansion.status.noKeywords", defaultValue: "No Keywords")
        case .accessibilityRequired:
            localization.string("permission.accessibility.title", defaultValue: "Permission Needed")
        case .ready:
            localization.string("settings.saved.expansion.status.listening", defaultValue: "Listening")
        case .unavailable:
            localization.string("settings.saved.expansion.status.unavailable", defaultValue: "Unavailable")
        }
    }

    private var keywordExpansionStatusColor: Color {
        switch settings.keywordExpansionStatus {
        case .ready: .green
        case .accessibilityRequired, .unavailable: .orange
        case .off, .noKeywords: .secondary
        }
    }

    private var keywordExpansionDiagnosticTitle: String? {
        guard settings.isKeywordExpansionEnabled else { return nil }
        switch settings.keywordExpansionDiagnostic {
        case .listening:
            return localization.string("settings.expansion.listening", defaultValue: "Waiting for typing in another app.")
        case .receivingTyping:
            return localization.string("settings.expansion.receiving", defaultValue: "Listening for a configured keyword.")
        case .expanded:
            return localization.string("settings.expansion.expanded", defaultValue: "Last keyword expanded successfully.")
        case .unsupportedEditor:
            return localization.string("settings.expansion.unsupported", defaultValue: "This field does not expose a supported, non-secure text editor. Paste the snippet from Clipboard instead.")
        case .focusUnavailable:
            return localization.string("settings.expansion.focusUnavailable", defaultValue: "The focused editor could not be reached. Try typing the keyword again.")
        case .focusOwnershipUnverified:
            return localization.string("settings.expansion.focusOwnershipUnverified", defaultValue: "The focused editor was found, but its app window could not be verified. Paste the snippet from Clipboard instead.")
        case .selectionUnavailable:
            return localization.string("settings.expansion.selection", defaultValue: "This editor does not expose its text selection. Paste the snippet from Clipboard instead.")
        case .contextChanged:
            return localization.string("settings.expansion.contextChanged", defaultValue: "The text or cursor changed before expansion; nothing was replaced.")
        case .templateUnavailable:
            return localization.string("settings.expansion.templateUnavailable", defaultValue: "The snippet is not ready. Retry after it finishes loading.")
        case .replacementUnavailable:
            return localization.string("settings.expansion.replacementUnavailable", defaultValue: "This editor did not allow text replacement. Paste the snippet from Clipboard instead.")
        case nil:
            return nil
        }
    }

    private var collectionSection: some View {
        PluginSettingsItem(
            title: localization.string("settings.collection.toggleTitle", defaultValue: "Enable Clipboard History"),
            description: collectionDescription,
            systemImage: "clipboard"
        ) {
            ClipboardSettingsSwitch(
                accessibilityLabel: localization.string("settings.collection.toggle", defaultValue: "Enable Clipboard History"),
                isOn: Binding(
                    get: { !settings.isPaused && presentation.snapshot.isCollectionOperational },
                    set: { isEnabled in
                        guard presentation.snapshot.isCollectionOperational else { return }
                        settings.setPaused(!isEnabled)
                    }
                )
            )
            .disabled(!presentation.snapshot.isCollectionOperational)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private var advancedSection: some View {
        VStack(spacing: 0) {
            exclusionsSection
            PluginSettingsListDivider()
            privateCopyShortcutsSection
            PluginSettingsListDivider()
            windowShortcutsSection
        }
    }

    private var windowShortcutsSection: some View {
        ClipboardSettingsDisclosure(
            isExpanded: $isWindowShortcutsExpanded,
            accessibilityValue: disclosureAccessibilityValue(isWindowShortcutsExpanded),
            headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
        ) {
            VStack(spacing: 0) {
                Text(localization.string("panel.shortcuts.group.description", defaultValue: "These shortcuts work only while the Clipboard window is focused."))
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()
                if let context = settingsContext {
                    ForEach(context.shortcutItems.filter {
                        $0.settingsGroupID == ClipboardHistoryPlugin.ShortcutID.panelGroup
                    }) { item in
                        PluginSettingsListDivider()
                        ClipboardSettingsShortcutRow(
                            title: item.settingsControlTitle ?? item.title,
                            description: item.description,
                            systemImage: item.settingsControlSystemImage ?? "keyboard",
                            bindingText: item.bindingText,
                            canAssign: true,
                            canClear: item.canClear,
                            localization: localization,
                            warnsAboutGlobalConflicts: false,
                            onRecord: { context.recordShortcut($0, for: item.id) },
                            onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                            onClear: { context.clearShortcut(for: item.id) }
                        )
                    }
                }
            }
        } label: {
            PluginSettingsItem(
                title: localization.string("panel.shortcuts.group", defaultValue: "Clipboard Window Shortcuts"),
                systemImage: "keyboard"
            ) {}
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsSearchAnchor(
            pluginID: ClipboardHistoryPlugin.pluginID,
            entryID: ClipboardHistoryPlugin.ShortcutID.panelGroup
        )
    }

    private var privateCopyShortcutsSection: some View {
        ClipboardSettingsDisclosure(
            isExpanded: $isPrivateCopyShortcutsExpanded,
            accessibilityValue: disclosureAccessibilityValue(isPrivateCopyShortcutsExpanded),
            headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
        ) {
            VStack(spacing: 0) {
                pluginShortcutRow(ClipboardHistoryPlugin.ShortcutID.privateCopy)
                PluginSettingsListDivider()
                pluginShortcutRow(ClipboardHistoryPlugin.ShortcutID.ignoreNextCopy)
            }
        } label: {
            PluginSettingsItem(
                title: localization.string("shortcut.group.title", defaultValue: "Private Copy Shortcuts"),
                systemImage: "eye.slash"
            ) {}
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
        .pluginSettingsSearchAnchor(
            pluginID: ClipboardHistoryPlugin.pluginID,
            entryID: ClipboardHistoryPlugin.ShortcutID.privacyGroup
        )
    }

    private func collectionControlIcon(_ actionID: String) -> String {
        switch actionID {
        case ClipboardHistoryPlugin.ActionID.pauseCollection: "pause.circle"
        case ClipboardHistoryPlugin.ActionID.resumeCollection: "play.circle"
        case ClipboardHistoryPlugin.ActionID.clearAllHistory: "trash"
        default: "playpause"
        }
    }

    private var collectionDescription: String {
        if let errorMessage = presentation.snapshot.historyErrorMessage {
            return errorMessage
        }
        if !presentation.snapshot.isHistoryLoaded {
            return localization.string(
                "settings.collection.loadingDescription",
                defaultValue: "正在准备本机加密存储…"
            )
        }
        if presentation.snapshot.isClearingHistory {
            return localization.string(
                "settings.collection.clearingDescription",
                defaultValue: "正在安全清除加密历史…"
            )
        }
        if settings.isPaused {
            return localization.string(
                "settings.collection.pausedDescription",
                defaultValue: "Recording is paused. Existing history is kept."
            )
        }
        return localization.string(
            "settings.collection.activeDescription",
            defaultValue: "Automatically save copied content to find and paste it later."
        )
    }

    private var sequentialPasteSection: some View {
        VStack(spacing: 0) {
            if let context = settingsContext,
               let item = context.shortcutItem(definitionID: "paste-sequentially") {
                ClipboardSettingsShortcutRow(
                    title: item.settingsControlTitle ?? item.title,
                    description: item.description,
                    systemImage: "list.number",
                    bindingText: item.bindingText,
                    canAssign: true,
                    canClear: item.canClear,
                    localization: localization,
                    onRecord: { context.recordShortcut($0, for: item.id) },
                    onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                    onClear: { context.clearShortcut(for: item.id) }
                )
            }
            PluginSettingsListDivider()
            sequentialPasteAdvancedOptions
        }
        .pluginSettingsSearchAnchor(
            pluginID: ClipboardHistoryPlugin.pluginID,
            entryID: ClipboardHistoryPlugin.ShortcutID.queueGroup
        )
    }

    private var sequentialPasteAdvancedOptions: some View {
        ClipboardSettingsDisclosure(
            isExpanded: $isQueueAdvancedExpanded,
            accessibilityValue: disclosureAccessibilityValue(isQueueAdvancedExpanded),
            headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
        ) {
            VStack(spacing: 0) {
                settingPickerRow(
                    title: localization.string(
                        "settings.sequentialPaste.dismiss.title",
                        defaultValue: "Hide Queue HUD After"
                    ),
                    description: localization.string(
                        "settings.sequentialPaste.dismiss.description",
                        defaultValue: "The movable HUD appears automatically after sequential paste."
                    ),
                    selection: $settings.sequentialHUDDismissal
                ) {
                    ForEach(ClipboardSequentialHUDDismissal.allCases) { option in
                        Text(sequentialHUDDismissalTitle(option)).tag(option)
                    }
                }
                PluginSettingsListDivider()
                PluginSettingsItem(
                    title: localization.string("settings.sequentialPaste.hidePreview.title", defaultValue: "Hide Content Preview"),
                    description: localization.string("settings.sequentialPaste.hidePreview.description", defaultValue: "Show only queue position and controls in the HUD."),
                    systemImage: "eye.slash"
                ) {
                    ClipboardSettingsSwitch(
                        accessibilityLabel: localization.string("settings.sequentialPaste.hidePreview.title", defaultValue: "Hide Content Preview"),
                        isOn: $settings.hidesSequentialHUDPreview
                    )
                }
                .pluginSettingsListRowPadding(interactive: true)
                if let context = settingsContext {
                    ForEach(ClipboardHistoryPlugin.queueControlActionIDs, id: \.self) { actionID in
                        if let item = context.actionShortcutItem(actionID: actionID) {
                            PluginSettingsListDivider()
                            ClipboardSettingsShortcutRow(
                                title: item.title,
                                description: item.description,
                                systemImage: queueControlIcon(actionID),
                                bindingText: item.bindingText,
                                canAssign: item.canAssign,
                                canClear: item.canClear,
                                localization: localization,
                                onRecord: { context.recordActionShortcut($0, for: actionID) },
                                onBeginRecording: nil,
                                onClear: { context.clearActionShortcut(for: actionID) }
                            )
                        }
                    }
                }
            }
        } label: {
            PluginSettingsItem(
                title: localization.string("settings.advanced.title", defaultValue: "Advanced"),
                systemImage: "slider.horizontal.3"
            ) {}
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private func queueControlIcon(_ actionID: String) -> String {
        switch actionID {
        case ClipboardHistoryPlugin.ActionID.previousSequentialQueueItem: "backward.end"
        case ClipboardHistoryPlugin.ActionID.skipSequentialQueueItem: "forward.end"
        case ClipboardHistoryPlugin.ActionID.restartSequentialQueue: "arrow.counterclockwise"
        default: "xmark.circle"
        }
    }

    private func sequentialHUDDismissalTitle(
        _ option: ClipboardSequentialHUDDismissal
    ) -> String {
        switch option {
        case .fiveSeconds:
            localization.string("settings.sequentialPaste.dismiss.5", defaultValue: "5 seconds")
        case .tenSeconds:
            localization.string("settings.sequentialPaste.dismiss.10", defaultValue: "10 seconds")
        case .thirtySeconds:
            localization.string("settings.sequentialPaste.dismiss.30", defaultValue: "30 seconds")
        case .never:
            localization.string("settings.sequentialPaste.dismiss.never", defaultValue: "Never")
        }
    }

    private var encryptedStorageStatusTitle: String {
        if presentation.snapshot.historyErrorMessage != nil {
            return localization.string("settings.storage.status.attention", defaultValue: "需要处理")
        }
        if presentation.snapshot.isHistoryLoaded {
            return localization.string("settings.storage.status.ready", defaultValue: "已就绪")
        }
        return localization.string("settings.storage.status.preparing", defaultValue: "准备中")
    }

    private var encryptedStorageStatusColor: Color {
        if presentation.snapshot.historyErrorMessage != nil {
            return .orange
        }
        return presentation.snapshot.isHistoryLoaded ? .green : .secondary
    }



    private var storageRecoveryDescription: String? {
        switch presentation.snapshot.storageError {
        case .keychain:
            localization.string(
                "settings.storage.recovery.keychain",
                defaultValue: "如 macOS 显示提示，请允许 MacTools 访问本机钥匙串，然后重试。现有历史记录尚未删除。"
            )
        case .missingEncryptionKey, .invalidEncryptionKey:
            localization.string(
                "settings.storage.recovery.missingKey",
                defaultValue: "现有数据库只有使用原来的加密密钥才能读取。请先尝试恢复该密钥；确认无法恢复后，才能删除无法读取的历史并重新开始。"
            )
        case .invalidEnvelope, .authenticationFailed, .historyTooLarge:
            localization.string(
                "settings.storage.recovery.unreadable",
                defaultValue: "原始加密数据已保留。请先重试；确认不再需要恢复时再删除它。"
            )
        case .insufficientDiskSpace, .unavailableStorage:
            localization.string(
                "settings.storage.recovery.unavailable",
                defaultValue: "解决本机存储问题后重试。问题解决前，剪贴板历史不会继续收集。"
            )
        case nil:
            nil
        }
    }

    private var retentionOptions: some View {
        VStack(spacing: 0) {
            settingPickerRow(
                title: localization.string("settings.retention.maximum.title", defaultValue: "最多保留"),
                description: localization.string(
                    "settings.retention.maximum.description",
                    defaultValue: "达到条数上限时，会自动移除最早的历史记录。已存项目不受影响。"
                ),
                selection: $settings.maximumItemCount
            ) {
                ForEach(ClipboardHistorySettingsStore.allowedItemCounts, id: \.self) { count in
                    Text(localization.format(
                        "settings.retention.itemCount",
                        defaultValue: "%d 条",
                        count
                    ))
                    .tag(count)
                }
            }
            PluginSettingsListDivider()
            settingPickerRow(
                title: localization.string(
                    "settings.retention.storageLimit.title",
                    defaultValue: "历史容量"
                ),
                description: localization.string(
                    "settings.retention.storageLimit.description",
                    defaultValue: "达到容量上限时移除最早的历史记录。实际保存仍受可用磁盘空间限制。"
                ),
                selection: $settings.maximumTotalPayloadByteCount
            ) {
                ForEach(ClipboardHistorySettingsStore.allowedTotalPayloadByteCounts, id: \.self) { count in
                    Text(byteCountTitle(count)).tag(count)
                }
            }
            PluginSettingsListDivider()
            settingPickerRow(
                title: localization.string("settings.retention.expiration.title", defaultValue: "闲置过期时间"),
                description: localization.string(
                    "settings.retention.expiration.description",
                    defaultValue: "按最后使用时间计算；未使用过的记录按添加时间计算。"
                ),
                selection: $settings.expiration
            ) {
                ForEach(ClipboardHistoryExpiration.allCases) { expiration in
                    Text(expirationTitle(expiration)).tag(expiration)
                }
            }
            PluginSettingsListDivider()
            settingPickerRow(
                title: localization.string("settings.retention.itemLimit.title", defaultValue: "Per-item Content Limit"),
                description: localization.string(
                    "settings.retention.itemLimit.description",
                    defaultValue: "Text, images, and embedded content above this explicit limit are not saved; files store references only."
                ),
                selection: $settings.maximumItemByteCount
            ) {
                ForEach(ClipboardHistorySettingsStore.allowedItemByteCounts, id: \.self) { count in
                    Text(byteCountTitle(count)).tag(count)
                }
            }
        }
    }

    private var retentionSummary: String {
        let itemLimit = localization.format(
            "settings.retention.itemCount",
            defaultValue: "%d items",
            settings.maximumItemCount
        )
        return [
            itemLimit,
            byteCountTitle(settings.maximumTotalPayloadByteCount),
            expirationTitle(settings.expiration),
        ].joined(separator: " · ")
    }

    private var exclusionsSection: some View {
        ClipboardSettingsDisclosure(
            isExpanded: $isExclusionsExpanded,
            accessibilityValue: disclosureAccessibilityValue(isExclusionsExpanded),
            headerHorizontalPadding: PluginSettingsTheme.Spacing.rowHorizontal
        ) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        chooseExcludedApplications()
                    } label: {
                        Label(localization.string("common.add", defaultValue: "添加"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .pluginSettingsListRowPadding(interactive: true)

                PluginSettingsListDivider()

                if settings.excludedApplications.isEmpty {
                    Text(localization.string("settings.exclusions.empty", defaultValue: "未排除任何应用"))
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                } else {
                    ForEach(Array(settings.excludedApplications.enumerated()), id: \.element.id) { index, app in
                        let localizedAppName = displayName(for: app)
                        PluginSettingsItem(title: localizedAppName, systemImage: "app") {
                            Button {
                                settings.removeExcludedApplication(bundleIdentifier: app.bundleIdentifier)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(localization.string("common.remove", defaultValue: "移除"))
                            .accessibilityLabel(localization.format(
                                "settings.exclusions.removeAccessibility",
                                defaultValue: "移除 %@",
                                localizedAppName
                            ))
                        }
                        .help(app.bundleIdentifier)
                        .pluginSettingsListRowPadding(interactive: true)
                        if index < settings.excludedApplications.count - 1 {
                            PluginSettingsListDivider()
                        }
                    }
                }
            }

            Text(localization.string(
                "settings.exclusions.footnote",
                defaultValue: "排除依据是复制发生时观察到的前台应用，不能替代密码管理器或安全输入保护。"
            ))
                .font(PluginSettingsTheme.Typography.rowDescription)
                .foregroundStyle(.secondary)
                .pluginSettingsListRowPadding()
        } label: {
            PluginSettingsItem(
                title: localization.string("settings.exclusions.section", defaultValue: "Excluded Apps"),
                description: exclusionsSummary,
                systemImage: "app.badge.checkmark"
            ) {}
        }
        .padding(.vertical, PluginSettingsTheme.Spacing.rowVertical)
    }

    private var exclusionsSummary: String {
        if settings.excludedApplications.isEmpty {
            return localization.string("settings.exclusions.empty", defaultValue: "No excluded apps")
        }
        let names = settings.excludedApplications.prefix(2).map(displayName(for:))
        let remainingCount = settings.excludedApplications.count - names.count
        if remainingCount == 0 {
            return names.joined(separator: ", ")
        }
        return names.joined(separator: ", ") + " +\(remainingCount)"
    }

    private var dataSection: some View {
        VStack(spacing: 0) {
            clearDataRow(
                title: localization.string("settings.data.history.title", defaultValue: "History"),
                description: localDataUsageSummary(presentation.snapshot.usage),
                systemImage: "clock.arrow.circlepath",
                request: .all,
                disabled: presentation.snapshot.historyErrorMessage != nil
                    || presentation.snapshot.historyItemCount == 0
                    || presentation.snapshot.isClearingHistory
            )
            PluginSettingsListDivider()
            clearDataRow(
                title: localization.string("settings.data.saved.title", defaultValue: "Saved Clips"),
                description: localization.string("settings.data.clearSaved.summary", defaultValue: "Remove saved clips; keep history and snippets."),
                systemImage: "bookmark",
                request: .savedClips,
                disabled: presentation.snapshot.historyErrorMessage != nil
                    || presentation.snapshot.savedItemCount == 0
                    || presentation.snapshot.isClearingHistory
            )
            PluginSettingsListDivider()
            clearDataRow(
                title: localization.string("settings.snippets.section", defaultValue: "Snippets"),
                description: localization.string("settings.data.clearSnippets.summary", defaultValue: "Delete snippets and their keywords; keep history and saved clips."),
                systemImage: "text.quote",
                request: .snippets,
                disabled: (presentation.snapshot.snippetCount == 0
                    && presentation.snapshot.savedFatalErrorMessage == nil)
                    || presentation.snapshot.savedErrorMessage != nil
            )
            if let backupService {
                PluginSettingsListDivider()
                ClipboardBackupRegion(
                    localization: localization,
                    controller: controller,
                    makeService: backupService,
                    suspend: onBackupSuspend,
                    resume: onBackupResume,
                    provisionalSavedMetadata: provisionalSavedMetadataForBackup
                )
            }
            if let errorMessage = presentation.snapshot.historyErrorMessage {
                PluginSettingsListDivider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pluginSettingsListRowPadding()

                if let recoveryDescription = storageRecoveryDescription {
                    Text(recoveryDescription)
                        .font(PluginSettingsTheme.Typography.rowDescription)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pluginSettingsListRowPadding()
                }

                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    Button(localization.string("settings.storage.retry", defaultValue: "重试")) {
                        controller.retryStorageAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if presentation.snapshot.canResetUnreadableHistory {
                        Button(localization.string(
                            "settings.storage.resetUnreadable",
                            defaultValue: "Delete Unreadable Clipboard Data…"
                        ), role: .destructive) {
                            clearRequest = .resetUnreadable
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()
                }
                .pluginSettingsListRowPadding(interactive: true)
            }
        }
    }

    private func clearDataRow(
        title: String, description: String, systemImage: String,
        request: ClipboardHistorySettingsClearRequest, disabled: Bool
    ) -> some View {
        PluginSettingsItem(title: title, description: description, systemImage: systemImage) {
            Button(role: .destructive) {
                clearRequest = request
            } label: {
                Text(localization.string("common.clear", defaultValue: "Clear") + "…")
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(title + " · " + localization.string("common.clear", defaultValue: "Clear"))
            .disabled(disabled)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func localDataUsageSummary(_ usage: ClipboardHistoryUsage) -> String {
        localization.format(
            "settings.data.savedCount",
            defaultValue: "%d / %d items · %@ / %@",
            usage.itemCount,
            settings.maximumItemCount,
            byteCountTitle(usage.payloadByteCount),
            byteCountTitle(settings.maximumTotalPayloadByteCount)
        )
    }

    private func disclosureAccessibilityValue(_ isExpanded: Bool) -> String {
        ClipboardHistorySetupAccessibility.disclosureValue(
            isExpanded: isExpanded,
            localization: localization
        )
    }

    private func displayName(for application: ClipboardExcludedApplication) -> String {
        let installedLocalizedName: String? = if let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        ),
           let applicationBundle = Bundle(url: applicationURL),
           let localizedName = (applicationBundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
               ?? applicationBundle.object(forInfoDictionaryKey: "CFBundleName")) as? String,
           !localizedName.isEmpty {
            localizedName
        } else {
            nil
        }
        return ClipboardExcludedApplicationDisplayName.resolve(
            application: application,
            installedLocalizedName: installedLocalizedName
        ) { key in
            switch key {
            case "excludedApplication.passwords":
                localization.string("excludedApplication.passwords", defaultValue: "密码")
            case "excludedApplication.keychainAccess":
                localization.string("excludedApplication.keychainAccess", defaultValue: "钥匙串访问")
            default:
                nil
            }
        }
    }

    @ViewBuilder
    private func pluginShortcutRow(_ definitionID: String) -> some View {
        if let context = settingsContext,
           let item = context.shortcutItem(definitionID: definitionID) {
            ClipboardSettingsShortcutRow(
                title: item.settingsControlTitle ?? item.title,
                description: item.description,
                systemImage: item.settingsControlSystemImage ?? "keyboard",
                bindingText: item.bindingText,
                canAssign: true,
                canClear: item.canClear,
                localization: localization,
                onRecord: { context.recordShortcut($0, for: item.id) },
                onBeginRecording: { context.beginShortcutRecording(for: item.id) },
                onClear: { context.clearShortcut(for: item.id) }
            )
        }
    }

    @ViewBuilder
    private func actionShortcutRow(_ actionID: String, systemImage: String) -> some View {
        if let context = settingsContext,
           let item = context.actionShortcutItem(actionID: actionID) {
            ClipboardSettingsShortcutRow(
                title: item.title,
                description: item.description,
                systemImage: systemImage,
                bindingText: item.bindingText,
                canAssign: item.canAssign,
                canClear: item.canClear,
                localization: localization,
                onRecord: { context.recordActionShortcut($0, for: actionID) },
                onBeginRecording: nil,
                onClear: { context.clearActionShortcut(for: actionID) }
            )
        }
    }

    private func settingPickerRow<Selection: Hashable, Content: View>(
        title: String,
        description: String,
        systemImage: String = "slider.horizontal.3",
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        PluginSettingsItem(title: title, description: description, systemImage: systemImage) {
            Picker(title, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .monospacedDigit()
                .frame(minWidth: 120, idealWidth: 160, maxWidth: 180, alignment: .trailing)
        }
        .pluginSettingsListRowPadding(interactive: true)
    }

    private func chooseExcludedApplications() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        PluginPresentationSafety.prepareForWindowOrdering()
        guard panel.runModal() == .OK else { return }

        let applications = panel.urls.compactMap { url -> ClipboardExcludedApplication? in
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  !identifier.isEmpty else {
                return nil
            }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return ClipboardExcludedApplication(bundleIdentifier: identifier, name: name)
        }
        settings.addExcludedApplications(applications)
    }

    private func expirationTitle(_ expiration: ClipboardHistoryExpiration) -> String {
        switch expiration {
        case .never: localization.string("settings.retention.expiration.never", defaultValue: "永不")
        case .oneDay: localization.string("settings.retention.expiration.oneDay", defaultValue: "1 天")
        case .sevenDays: localization.string("settings.retention.expiration.sevenDays", defaultValue: "7 天")
        case .thirtyDays: localization.string("settings.retention.expiration.thirtyDays", defaultValue: "30 天")
        case .ninetyDays: localization.string("settings.retention.expiration.ninetyDays", defaultValue: "90 天")
        }
    }

    private func byteCountTitle(_ byteCount: Int) -> String {
        if byteCount >= 1_024 * 1_024 * 1_024 {
            return localization.format(
                "settings.retention.byteCount.gigabytes",
                defaultValue: "%d GB",
                byteCount / (1_024 * 1_024 * 1_024)
            )
        }
        return byteCount >= 1_024 * 1_024
            ? localization.format(
                "settings.retention.byteCount.megabytes",
                defaultValue: "%d MB",
                byteCount / (1_024 * 1_024)
            )
            : localization.format(
                "settings.retention.byteCount.kilobytes",
                defaultValue: "%d KB",
                byteCount / 1_024
            )
    }
}

@MainActor
private struct ClipboardSettingsShortcutRow: View {
    let title: String
    let description: String
    let systemImage: String
    let bindingText: String
    let canAssign: Bool
    let canClear: Bool
    let localization: PluginLocalization
    var warnsAboutGlobalConflicts = true
    let onRecord: (ShortcutBinding) -> PluginShortcutRecordingResult
    let onBeginRecording: (() -> Void)?
    let onClear: () -> Void
    @State private var displayedBinding: String?
    @State private var pendingBinding: ShortcutBinding?
    @State private var showsConflictWarning = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: PluginSettingsTheme.Spacing.rowTitleDescription) {
            PluginSettingsItem(title: title, description: description, systemImage: systemImage) {
                PluginSettingsShortcutRecorderControl(
                    title: title,
                    displayText: displayedBinding ?? bindingText,
                    canAssign: canAssign,
                    canClear: displayedBinding.map { !$0.isEmpty } ?? canClear,
                    clearTitle: localization.string("common.remove", defaultValue: "移除"),
                    onRecord: { binding in
                        if warnsAboutGlobalConflicts && CommonApplicationShortcutBindings.requiresConflictWarning(for: binding) {
                            pendingBinding = binding
                            showsConflictWarning = true
                            return .accepted
                        }
                        return save(binding)
                    },
                    onBeginRecording: {
                        errorMessage = nil
                        onBeginRecording?()
                    },
                    onClear: {
                        onClear()
                        displayedBinding = ""
                        errorMessage = nil
                    }
                )
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(PluginSettingsTheme.Typography.rowDescription)
                    .foregroundStyle(.red)
            }
        }
        .pluginSettingsListRowPadding(interactive: true)
        .onChange(of: bindingText) { _, _ in displayedBinding = nil }
        .alert(
            localization.format(
                "settings.shortcut.commonConflictWarning.title",
                defaultValue: "仍要使用“%@”？",
                pendingBinding.map { ShortcutFormatter.displayString(for: $0) } ?? ""
            ),
            isPresented: $showsConflictWarning
        ) {
            Button(localization.string("settings.shortcut.commonConflictWarning.confirm", defaultValue: "仍要使用")) {
                if let pendingBinding { _ = save(pendingBinding) }
                pendingBinding = nil
            }
            Button(localization.string("common.cancel", defaultValue: "取消"), role: .cancel) {
                pendingBinding = nil
            }
        } message: {
            Text(localization.string(
                "settings.shortcut.commonConflictWarning.message",
                defaultValue: "这是全局快捷键，可能覆盖其他应用的常用操作。"
            ))
        }
    }

    private func save(_ binding: ShortcutBinding) -> PluginShortcutRecordingResult {
        let result = onRecord(binding)
        switch result {
        case .accepted:
            displayedBinding = ShortcutFormatter.displayString(for: binding)
            errorMessage = nil
        case let .rejected(message):
            errorMessage = message
        }
        return result
    }
}

private enum ClipboardHistorySettingsClearRequest: String, Identifiable {
    case all
    case savedClips
    case snippets
    case resetUnreadable

    var id: String { rawValue }
}

private struct ClipboardSettingsSwitch: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let accessibilityLabel: String
    @Binding var isOn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeNSView(context: Context) -> ClipboardAccessibleSwitch {
        let control = ClipboardAccessibleSwitch()
        control.controlSize = .small
        control.isEnabled = isEnabled
        control.target = context.coordinator
        control.action = #selector(Coordinator.didToggle(_:))
        control.setAccessibilityLabel(accessibilityLabel)
        control.state = isOn ? .on : .off
        return control
    }

    func updateNSView(_ control: ClipboardAccessibleSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(accessibilityLabel)
        control.state = isOn ? .on : .off
    }

    @MainActor
    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func didToggle(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}

private final class ClipboardAccessibleSwitch: NSSwitch {
    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }
}

struct ClipboardSettingsDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    private let accessibilityValue: String
    private let headerHorizontalPadding: CGFloat
    private let label: Label
    private let content: Content

    init(
        isExpanded: Binding<Bool>,
        accessibilityValue: String,
        headerHorizontalPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        _isExpanded = isExpanded
        self.accessibilityValue = accessibilityValue
        self.headerHorizontalPadding = headerHorizontalPadding
        self.content = content()
        self.label = label()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            label
        }
        .disclosureGroupStyle(ClipboardSettingsDisclosureStyle(
            accessibilityValue: accessibilityValue,
            headerHorizontalPadding: headerHorizontalPadding
        ))
    }
}

private struct ClipboardSettingsDisclosureStyle: DisclosureGroupStyle {
    let accessibilityValue: String
    let headerHorizontalPadding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: configuration.isExpanded ? PluginSettingsTheme.Spacing.sectionHeaderContent : 0) {
            Button {
                // Keep the full-row hit target without fading/sliding the form
                // or interpolating its scroll position as sections change size.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: PluginSettingsTheme.Spacing.rowContentControl) {
                    configuration.label
                    Spacer(minLength: PluginSettingsTheme.Spacing.rowContentControl)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .padding(.horizontal, headerHorizontalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(accessibilityValue))

            if configuration.isExpanded {
                configuration.content
                    .transition(.identity)
            }
        }
    }
}
