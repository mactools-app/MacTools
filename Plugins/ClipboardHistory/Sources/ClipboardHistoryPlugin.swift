import AppKit
import Foundation
import ImageIO
import MacToolsPluginKit
import SwiftUI

public final class ClipboardHistoryPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        ClipboardHistoryPluginProvider(context: context)
    }
}

@MainActor
private struct ClipboardHistoryPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [ClipboardHistoryPlugin(context: context)]
    }
}

@MainActor
final class ClipboardHistoryPlugin:
    MacToolsPlugin, PluginActionProviding, PluginGroupedShortcutSettingsProviding, PluginShortcutSettingsGroupPresentationProviding, PluginShortcutBindingValidating, PluginInlineShortcutSettingsContextConsuming, PluginShortcutResetRequesting, PluginWindowLayoutTargetProviding, PluginSettingsPresenting, AccessibilityPermissionRefreshing, DisplayTopologyRefreshing {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    static let pluginID = "clipboard"
    static let pluginOrder = 125

    enum ActionID {
        static let openHistory = "open-history"
        static let previousSequentialQueueItem = "previous-sequential-queue-item"
        static let skipSequentialQueueItem = "skip-sequential-queue-item"
        static let restartSequentialQueue = "restart-sequential-queue"
        static let cancelSequentialQueue = "cancel-sequential-queue"
        static let pauseCollection = "pause-collection"
        static let resumeCollection = "resume-collection"
        static let toggleCollection = "toggle-collection"
        static let clearAllHistory = "clear-all-history"

        static let all: Set<String> = [
            openHistory,
            previousSequentialQueueItem,
            skipSequentialQueueItem,
            restartSequentialQueue,
            cancelSequentialQueue,
            pauseCollection,
            resumeCollection,
            toggleCollection,
            clearAllHistory,
        ]
    }

    enum ShortcutID {
        static let privateCopy = "private-copy"
        static let ignoreNextCopy = "ignore-next-copy"
        static let pastePlainText = "paste-clipboard-as-plain-text"
        static let pasteSequentially = "paste-sequentially"
        static let panelActions = "panel-actions"
        static let panelExport = "panel-export"
        static let panelEditSnippet = "panel-edit-snippet"
        static let panelShare = "panel-share"
        static let panelSave = "panel-save"
        static let panelDelete = "panel-delete"
        static let panelMultiSelect = "panel-multi-select"
        static let panelToggleSelection = "panel-toggle-selection"
        static let panelSelectAll = "panel-select-all"
        static let panelCopyCombined = "panel-copy-combined"
        static let panelPasteCombined = "panel-paste-combined"
        static let panelCycleScope = "panel-cycle-scope"
        static let primaryGroup = "primary-shortcuts"
        static let panelGroup = "clipboard-window-shortcuts"
        static let queueGroup = "sequential-paste-shortcuts"
        static let privacyGroup = "privacy-copy-shortcuts"
        static let collectionGroup = "collection-shortcuts"
    }

    private enum PermissionID {
        static let accessibility = "accessibility"
    }

    private enum SettingsSectionID {
        static let history = "clipboard-essential-settings"
        static let queue = "clipboard-queue-settings"
        static let snippets = "clipboard-snippet-settings"
        static let advanced = "clipboard-additional-shortcuts"
        static let data = "clipboard-data-settings"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: Self.pluginID,
            title: localization.string("metadata.title", defaultValue: "剪贴板"),
            iconName: "clipboard",
            iconTint: .accentColor,
            order: Self.pluginOrder,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "搜索历史记录并管理可重复使用的片段和已存项目"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor
    let controller: ClipboardHistoryController
    let savedLibraryController: ClipboardSavedLibraryController

    var onStateChange: (() -> Void)?
    var requestSettingsPresentation: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var inlineShortcutSettingsContextProvider: (() -> PluginSettingsContext)?
    var resetShortcutCustomizations: (([String]) -> Void)?
    var focusedWindowLayoutTarget: NSWindow? {
        panelController.focusedWindowLayoutTarget
    }

    func shortcutValidationMessage(
        definitionID: String,
        binding: ShortcutBinding
    ) -> String? {
        if definitionID == ShortcutID.panelCycleScope,
           binding.modifiers.contains(.shift) {
            return localization.string(
                "panel.shortcuts.cycleScope.shiftReserved",
                defaultValue: "Shift is reserved for cycling backward. Record the forward shortcut without Shift."
            )
        }

        if let reverseConflictOwner = reverseCycleShortcutConflictOwner(
            definitionID: definitionID,
            binding: binding
        ) {
            return localization.format(
                "panel.shortcuts.reverseCycleConflict",
                defaultValue: "This key is reserved for cycling filters backward by %@.",
                reverseConflictOwner
            )
        }

        guard (Self.panelShortcutDefinitionIDs.contains(definitionID)
                || ClipboardItemShortcutStore.itemID(for: definitionID) != nil),
              let owner = fixedClipboardCommandOwner(for: binding)
        else { return nil }
        return localization.format(
            "panel.shortcuts.fixedConflict",
            defaultValue: "This key is used by the Clipboard window for %@.",
            owner
        )
    }

    private func fixedClipboardCommandOwner(for binding: ShortcutBinding) -> String? {
        switch binding {
        case ClipboardHistoryFixedShortcut.close:
            return localization.string("common.close", defaultValue: "Close")
        case ClipboardHistoryFixedShortcut.paste:
            return localization.string("common.paste", defaultValue: "Paste")
        case ClipboardHistoryFixedShortcut.pastePlainText:
            return localization.string("panel.pastePlain", defaultValue: "Paste as Plain Text")
        case ClipboardHistoryFixedShortcut.copy:
            return localization.string("common.copy", defaultValue: "Copy")
        case ClipboardHistoryFixedShortcut.previous,
             ClipboardHistoryFixedShortcut.next,
             ClipboardHistoryFixedShortcut.previousAlternate,
             ClipboardHistoryFixedShortcut.nextAlternate:
            return localization.string("panel.footer.navigate", defaultValue: "Navigate")
        case ClipboardHistoryFixedShortcut.extendPrevious,
             ClipboardHistoryFixedShortcut.extendNext:
            return localization.string("panel.selection.extend", defaultValue: "Extend Selection")
        default:
            if ClipboardHistoryFixedShortcut.numberKeyCodes.contains(binding.keyCode),
               binding.modifiers == .command {
                return localization.string("panel.shortcuts.quickPaste", defaultValue: "Quick Paste")
            }
            if ClipboardHistoryFixedShortcut.numberKeyCodes.contains(binding.keyCode),
               binding.modifiers == .control {
                return localization.string("panel.shortcuts.chooseFilter", defaultValue: "Choose Filter")
            }
            return nil
        }
    }

    private func reverseCycleShortcutConflictOwner(
        definitionID: String,
        binding: ShortcutBinding
    ) -> String? {
        guard let shortcutBindingResolver else { return nil }

        if definitionID == ShortcutID.panelCycleScope {
            let reverseBinding = ShortcutBinding(
                keyCode: binding.keyCode,
                modifiers: binding.modifiers.union(.shift)
            )
            guard let conflictingDefinitionID = Self.panelShortcutDefinitionIDs.first(where: {
                $0 != ShortcutID.panelCycleScope
                    && shortcutBindingResolver($0) == reverseBinding
            }) else { return nil }
            return shortcutDefinitionTitle(conflictingDefinitionID)
        }

        guard let forwardBinding = shortcutBindingResolver(ShortcutID.panelCycleScope) else {
            return nil
        }
        let reverseBinding = ShortcutBinding(
            keyCode: forwardBinding.keyCode,
            modifiers: forwardBinding.modifiers.union(.shift)
        )
        guard binding == reverseBinding else { return nil }
        return shortcutDefinitionTitle(ShortcutID.panelCycleScope)
    }

    private func shortcutDefinitionTitle(_ definitionID: String) -> String {
        shortcutDefinitions.first(where: { $0.id == definitionID })?.title ?? definitionID
    }

    static let panelShortcutDefinitionIDs: Set<String> = [
        ShortcutID.panelActions,
        ShortcutID.panelCycleScope,
        ShortcutID.panelExport,
        ShortcutID.panelEditSnippet,
        ShortcutID.panelShare,
        ShortcutID.panelSave,
        ShortcutID.panelDelete,
        ShortcutID.panelMultiSelect,
        ShortcutID.panelToggleSelection,
        ShortcutID.panelSelectAll,
        ShortcutID.panelCopyCombined,
        ShortcutID.panelPasteCombined,
    ]

    private let settingsStore: ClipboardHistorySettingsStore
    private let privateCopyLeaseStore: PluginStorageClipboardPrivateCopyLeaseStore
    private let pasteboard: any ClipboardPasteboardAccess
    private let localization: PluginLocalization
    private let copyCommandSender: any ClipboardCopyCommandSending
    private let pasteCommandSender: any ClipboardPasteCommandSending
    let itemShortcutStore: ClipboardItemShortcutStore
    private var itemShortcutTailTask: Task<Void, Never>?
    private struct ItemShortcutRequestKey: Hashable {
        let itemID: UUID
        let pasteFormat: ClipboardItemShortcutStore.PasteFormat
    }

    private var itemShortcutRequestGeneration: [ItemShortcutRequestKey: UInt64] = [:]
    private var activeItemShortcutAssignments: Set<UUID> = []
    private var waitingItemShortcutAssignments: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var cachedItemShortcutDefinitions: [PluginShortcutDefinition] = []
    private struct ItemShortcutContentRevision: Equatable {
        let history: UInt64
        let snippets: UInt64
        let itemIDs: Set<UUID>
    }
    private var itemShortcutContentRevision: ItemShortcutContentRevision?
    private var shortcutHistoryItems: [UUID: ClipboardHistoryItem] = [:]
    private var shortcutSnippets: [UUID: ClipboardSavedItem] = [:]
    private var itemShortcutLifecycleGeneration: UInt64 = 0
    private var activeProvisionalShortcutSaves: [UUID: ClipboardHistorySavedMetadata] = [:]
    private var pendingShortcutSaveRollbacks: [UUID: ClipboardHistorySavedMetadata] = [:]
    private let accessibilityTrusted: () -> Bool
    private let accessibilityRequester: (Bool) -> Bool
    private let frontmostProcessIdentifier: () -> pid_t?
    private let sequentialPasteStabilizationDelay: Duration
    private let snippetPasteboardReader: ClipboardPasteboardReaderProcess
    private lazy var keywordExpander = ClipboardSnippetKeywordExpander(
        savedLibraryController: savedLibraryController,
        pasteboard: pasteboard,
        pasteboardReader: snippetPasteboardReader,
        onPasteboardWrite: { [weak self] in self?.controller.markCurrentPasteboardChangeAsInternal() }
    )
    private let privacyHUDPresenter: any ClipboardPrivacyHUDPresenting
    private let backupPersistence: IncrementalEncryptedClipboardHistoryStore?
    private var isBackingUpClipboard = false
    private let databaseAccess: ClipboardDatabaseAccessCoordinator
    private let sequentialPasteCoordinator: ClipboardSequentialPasteCoordinator
    private var pendingSequentialPasteTargets: [pid_t?] = []
    private var isSequentialPasteInFlight = false
    private var sequentialPasteWorkerTask: Task<Void, Never>?
    private var sequentialPasteWorkerGeneration = 0
    private var sequentialQueueCreationTask: Task<Bool, Never>?
    private var sequentialQueueCreationGeneration = 0
    private var sequentialQueueRestoreTask: Task<Void, Never>?
    private var sequentialHUDPreviewTask: Task<Void, Never>?
    private var privateCopyTask: Task<Void, Never>?
    private var privateCopyGeneration: UInt64 = 0
    private(set) var keywordExpansionStartAttemptCountForTesting = 0
    var hasPendingSequentialPasteForTesting: Bool {
        sequentialQueueCreationTask != nil
            || sequentialPasteWorkerTask != nil
            || isSequentialPasteInFlight
            || !pendingSequentialPasteTargets.isEmpty
    }
    var hasPrivateCopyOperationForTesting: Bool { privateCopyTask != nil }
    var sequentialPasteHUDForTesting: ClipboardSequentialPasteHUDController { sequentialPasteHUD }
    var isKeywordExpansionRunningForTesting: Bool { keywordExpander.isRunning }
    var hasConfiguredKeywordExpansionForTesting: Bool { keywordExpander.hasConfiguredKeywords }
    var snippetPasteboardReaderForTesting: ClipboardPasteboardReaderProcess { snippetPasteboardReader }
    var historyPasteboardReaderForTesting: ClipboardPasteboardReaderProcess? {
        (pasteboard as? GeneralClipboardPasteboard)?.payloadReaderForTesting
    }
    private lazy var sequentialPasteHUD: ClipboardSequentialPasteHUDController = {
        let hud = ClipboardSequentialPasteHUDController(localization: localization)
        hud.onPasteNext = { [weak self] in
            guard let self else { return }
            self.enqueueSequentialPaste(
                targetProcessIdentifier: self.frontmostProcessIdentifier()
            )
        }
        hud.onPrevious = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            Task { @MainActor in
                guard !self.isSequentialQueueMutationLocked else { return }
                if await self.sequentialPasteCoordinator.moveToPrevious() {
                    self.sequentialQueueDidChange()
                } else {
                    self.showSequentialPersistenceFailure()
                }
            }
        }
        hud.onSkip = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            Task { @MainActor in
                guard !self.isSequentialQueueMutationLocked else { return }
                if await self.sequentialPasteCoordinator.skip() {
                    self.sequentialQueueDidChange()
                } else {
                    self.showSequentialPersistenceFailure()
                }
            }
        }
        hud.onRestart = { [weak self] in
            guard let self, !self.isSequentialQueueMutationLocked else { return }
            Task { @MainActor in
                guard !self.isSequentialQueueMutationLocked else { return }
                if await self.sequentialPasteCoordinator.restart() {
                    self.sequentialQueueDidChange()
                } else {
                    self.showSequentialPersistenceFailure()
                }
            }
        }
        hud.onCancel = { [weak self] in
            guard let self, !self.isBackingUpClipboard else { return }
            self.cancelPendingSequentialPastes()
            self.sequentialHUDPreviewTask?.cancel()
            self.sequentialHUDPreviewTask = nil
            Task { @MainActor [weak self] in
                guard let self, !self.isBackingUpClipboard else { return }
                if await self.sequentialPasteCoordinator.cancel() {
                    self.synchronizeSequentialPasteProtection()
                    self.sequentialPasteHUD.dismiss()
                } else {
                    self.showSequentialPersistenceFailure()
                }
            }
        }
        hud.onClose = { [weak self] in
            self?.sequentialHUDPreviewTask?.cancel()
            self?.sequentialHUDPreviewTask = nil
        }
        return hud
    }()
    private var isPanelPreparationPending = false
    private lazy var panelController = ClipboardHistoryPanelController(
        historyController: controller,
        savedLibraryController: savedLibraryController,
        itemShortcutStore: itemShortcutStore,
        previewPasteboard: pasteboard,
        localization: localization,
        onIgnoreNextCopy: { [weak self] in
            self?.armIgnoreNextCopy()
        },
        onManualClipboardWrite: { [weak self] in
            self?.resetImplicitQueueForManualClipboardWrite()
        },
        onStartSequentialQueue: { [weak self] itemIDs in
            guard let self else { return false }
            return await self.requestSequentialQueueCreation(itemIDs: itemIDs)
        },
        onAssignItemShortcut: { [weak self] itemID, format, lifetime, binding in
            await self?.assignItemShortcut(
                itemID: itemID, pasteFormat: format, lifetime: lifetime, binding: binding
            )
                ?? .rejected("Unavailable")
        },
        itemShortcutAssignment: { [weak self] itemID, format in
            self?.itemShortcutStore.assignment(for: itemID, pasteFormat: format)
        },
        onRemoveItemShortcut: { [weak self] itemID, format in
            self?.removeItemShortcut(itemID: itemID, pasteFormat: format)
        },
        onPrepareForPermanentDeletion: { [weak self] itemIDs in
            guard let self else { return false }
            return await self.prepareForPermanentDeletion(itemIDs: Set(itemIDs))
        },
        hudPresenter: privacyHUDPresenter,
        pasteCommandSender: pasteCommandSender,
        shortcutBindingProvider: { [weak self] shortcutID in
            guard let self else { return nil }
            if let shortcutBindingResolver = self.shortcutBindingResolver {
                return shortcutBindingResolver(shortcutID)
            }
            return Self.defaultPanelShortcutBinding(shortcutID)
        },
        shortcutSettingsContextProvider: { [weak self] in
            self?.inlineShortcutSettingsContextProvider?()
        },
        onOpenSettings: { [weak self] in
            self?.requestSettingsPresentation?()
        },
        onOpenShortcutSettings: {
            guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
                  let scheme = urlTypes.compactMap({ ($0["CFBundleURLSchemes"] as? [String])?.first }).first,
                  let url = URL(string: "\(scheme)://app/settings/features/actions-and-shortcuts") else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    )

    init(
        context: PluginRuntimeContext,
        pasteboard: (any ClipboardPasteboardAccess)? = nil,
        sourceContext: (any ClipboardSourceContextProviding)? = nil,
        persistence: (any ClipboardHistoryPersisting)? = nil,
        savedPersistence: (any ClipboardSavedLibraryPersisting)? = nil,
        copyCommandSender: (any ClipboardCopyCommandSending)? = nil,
        pasteCommandSender: (any ClipboardPasteCommandSending)? = nil,
        privacyHUDPresenter: (any ClipboardPrivacyHUDPresenting)? = nil,
        imageTextRecognizer: (any ClipboardImageTextRecognizing)? = nil,
        accessibilityTrusted: @escaping () -> Bool = ClipboardHistoryAccessibilityCheck.isTrusted,
        accessibilityRequester: @escaping (Bool) -> Bool = ClipboardHistoryAccessibilityCheck.requestTrust(prompt:),
        frontmostProcessIdentifier: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        sequentialPasteStabilizationDelay: Duration = .milliseconds(120),
        snippetPasteboardReader: ClipboardPasteboardReaderProcess? = nil,
        sequentialPasteStore: (any ClipboardSequentialPasteSessionPersisting)? = nil,
        initialSequentialPasteSession: ClipboardSequentialPasteSession? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        let settingsStore = ClipboardHistorySettingsStore(storage: context.storage)
        let privateCopyLeaseStore = PluginStorageClipboardPrivateCopyLeaseStore(storage: context.storage)
        let snippetPasteboardReaderHelperURL = context.resourceBundle.url(
            forResource: "mactools-clipboard-pasteboard-reader-helper",
            withExtension: nil,
            subdirectory: "PasteboardReaderHelper"
        )
        let resolvedSnippetPasteboardReader = snippetPasteboardReader ?? ClipboardPasteboardReaderProcess {
            snippetPasteboardReaderHelperURL
        }
        let resolvedPasteboard = pasteboard ?? GeneralClipboardPasteboard(
            resourceBundle: context.resourceBundle
        )
        let resolvedSavedLibraryPasteboard: any ClipboardPasteboardAccess = pasteboard ?? GeneralClipboardPasteboard(
            resourceBundle: context.resourceBundle,
            payloadReader: resolvedSnippetPasteboardReader
        )
        let databaseURL = context.supportDirectory?.appendingPathComponent(
            "clipboard.sqlite3",
            isDirectory: false
        )
        let keyStore = ClipboardHistoryKeychainStore(
            service: PluginPrivateDataKeychainIdentity.service(pluginID: Self.pluginID)
        )
        let databaseAccess = ClipboardDatabaseAccessCoordinator()
        let resolvedSequentialPasteStore: any ClipboardSequentialPasteSessionPersisting
        if let sequentialPasteStore {
            resolvedSequentialPasteStore = sequentialPasteStore
        } else if let databaseURL {
            resolvedSequentialPasteStore = EncryptedClipboardSequentialPasteStore(
                databaseURL: databaseURL,
                keyStore: keyStore,
                databaseAccess: databaseAccess
            )
        } else {
            resolvedSequentialPasteStore = ClipboardSequentialPasteMemoryStore()
        }
        let sequentialPasteCoordinator = ClipboardSequentialPasteCoordinator(
            store: resolvedSequentialPasteStore,
            initialSession: initialSequentialPasteSession
        )
        let resolvedPersistence: any ClipboardHistoryPersisting
        if let persistence {
            resolvedPersistence = persistence
        } else if let databaseURL {
            resolvedPersistence = IncrementalEncryptedClipboardHistoryStore(
                databaseURL: databaseURL,
                keyStore: keyStore,
                databaseAccess: databaseAccess
            )
        } else {
            resolvedPersistence = UnavailableClipboardHistoryStore()
        }
        let resolvedSavedPersistence: any ClipboardSavedLibraryPersisting
        if let savedPersistence {
            resolvedSavedPersistence = savedPersistence
        } else if let databaseURL {
            resolvedSavedPersistence = IncrementalEncryptedClipboardSavedLibraryStore(
                databaseURL: databaseURL,
                keyStore: keyStore,
                databaseAccess: databaseAccess
            )
        } else {
            resolvedSavedPersistence = UnavailableClipboardSavedLibraryStore()
        }

        self.localization = localization
        self.settingsStore = settingsStore
        self.privateCopyLeaseStore = privateCopyLeaseStore
        let itemShortcutStore = ClipboardItemShortcutStore(storage: context.storage)
        self.itemShortcutStore = itemShortcutStore
        self.pasteboard = resolvedPasteboard
        self.copyCommandSender = copyCommandSender ?? SystemClipboardCopyCommandSender()
        self.pasteCommandSender = pasteCommandSender ?? SystemClipboardPasteCommandSender()
        self.privacyHUDPresenter = privacyHUDPresenter ?? ClipboardPrivacyHUDController(localization: localization)
        self.backupPersistence = resolvedPersistence as? IncrementalEncryptedClipboardHistoryStore
        self.databaseAccess = databaseAccess
        self.sequentialPasteCoordinator = sequentialPasteCoordinator
        self.accessibilityTrusted = accessibilityTrusted
        self.accessibilityRequester = accessibilityRequester
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.sequentialPasteStabilizationDelay = sequentialPasteStabilizationDelay
        self.snippetPasteboardReader = resolvedSnippetPasteboardReader
        self.controller = ClipboardHistoryController(
            settings: settingsStore,
            pasteboard: resolvedPasteboard,
            sourceContext: sourceContext ?? WorkspaceClipboardSourceContextProvider(),
            persistence: resolvedPersistence,
            imageTextRecognizer: imageTextRecognizer ?? VisionClipboardImageTextRecognizer(),
            copyEventMonitor: SystemClipboardCopyEventMonitor(),
            shortcutRetainedItemIDs: itemShortcutStore.activeHistoryItemIDs,
            errorMessageProvider: { error in
                Self.localizedErrorMessage(error, localization: localization)
            }
        )
        self.savedLibraryController = ClipboardSavedLibraryController(
            pasteboard: resolvedSavedLibraryPasteboard,
            persistence: resolvedSavedPersistence,
            errorMessageProvider: { error in
                Self.localizedErrorMessage(error, localization: localization)
            }
        )
        self.savedLibraryController.maximumExpandedTextByteCount = { [weak settingsStore] in
            ClipboardHistorySettingsStore.validExpandedTextByteCount(settingsStore?.maximumExpandedTextByteCount ?? 0)
        }
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: {
                localization.string("panel.button.open", defaultValue: "打开")
            }
        )

        itemShortcutStore.onRemoved = { [weak self] removed in
            guard let self else { return }
            if let resetShortcutCustomizations = self.resetShortcutCustomizations {
                resetShortcutCustomizations(removed.map(\.definitionID))
            } else {
                let context = self.inlineShortcutSettingsContextProvider?()
                for assignment in removed {
                    context?.resetShortcut(for: "\(Self.pluginID).shortcut.\(assignment.definitionID)")
                }
            }
            self.onStateChange?()
        }
        itemShortcutStore.onAssignmentsChanged = { [weak self] in
            guard let self else { return }
            self.refreshItemShortcutDefinitions()
            self.synchronizeItemShortcutRetention()
        }

        settingsStore.onChange = { [weak self] in
            self?.controller.settingsDidChange()
            self?.synchronizeKeywordExpansion()
        }
        controller.onChange = { [weak self] in
            self?.preparePanelWhenReady()
            self?.retryPendingShortcutSaveRollbacksWhenReady()
            self?.pruneItemShortcutsWhenReady()
            self?.refreshItemShortcutDefinitions()
            self?.onStateChange?()
        }
        savedLibraryController.onChange = { [weak self] in
            self?.preparePanelWhenReady()
            self?.pruneItemShortcutsWhenReady()
            self?.refreshItemShortcutDefinitions()
            self?.synchronizeKeywordExpansion()
            self?.onStateChange?()
        }
        savedLibraryController.onPasteboardWrite = { [weak self] in
            self?.controller.markCurrentPasteboardChangeAsInternal()
            self?.resetImplicitQueueForManualClipboardWrite()
        }
        controller.onCaptureSuppressionEvent = { [weak privacyHUDPresenter = self.privacyHUDPresenter] event in
            privacyHUDPresenter?.handleSuppressionEvent(event)
        }
        controller.onPrivateCopyLeaseChange = { [weak privateCopyLeaseStore] lease in
            if let lease {
                privateCopyLeaseStore?.save(
                    baselineChangeCount: lease.baselineChangeCount,
                    expiresAt: lease.expiresAt
                )
            } else {
                privateCopyLeaseStore?.clear()
            }
        }
        controller.onCaptureRejection = {
            [weak privacyHUDPresenter = self.privacyHUDPresenter, localization = self.localization]
            reason,
            limit in
            switch reason {
            case .oversized:
                privacyHUDPresenter?.showFailure(localizedMessage: { [localization] in localization.format(
                    "hud.capture.oversized",
                    defaultValue: "未保存：内容超过 %d MB",
                    max(1, limit / (1_024 * 1_024))
                ) })
            case .historyCapacityFull:
                privacyHUDPresenter?.showFailure(localizedMessage: { [localization] in localization.string(
                    "hud.capture.capacityFull",
                    defaultValue: "Not saved: History capacity is full"
                ) })
            case .tooManyObjects:
                privacyHUDPresenter?.showFailure(localizedMessage: { [localization] in localization.format(
                    "hud.capture.tooManyObjects",
                    defaultValue: "未保存：剪贴板项目超过 %d 个",
                    limit
                ) })
            default:
                break
            }
        }
        controller.onExternalPasteboardChange = { [weak self] in
            guard let self else { return }
            self.resetImplicitQueueForManualClipboardWrite()
        }
        controller.onWillClearHistory = { [weak self] in
            self?.prepareForHistoryClear()
        }
        controller.onWillResetPersistentHistory = { [weak self] in
            self?.cancelPendingSequentialPastes()
            self?.cancelSequentialQueueCreation()
            self?.sequentialQueueRestoreTask?.cancel()
            self?.sequentialQueueRestoreTask = nil
            self?.sequentialPasteCoordinator.prepareForStorageReset()
            self?.synchronizeSequentialPasteProtection()
            self?.sequentialPasteHUD.dismiss()
        }
        controller.updateSequentialPasteProtectedItemIDs(
            sequentialPasteCoordinator.protectedItemIDs()
        )
        refreshItemShortcutDefinitions()
    }

    var settingsPage: PluginSettingsPage? {
        .form(
            description: localization.string(
                "metadata.description",
                defaultValue: "Search encrypted local History and manage reusable Saved items"
            ),
            sections: [
                settingsSection(
                    id: SettingsSectionID.history,
                    title: localization.string("settings.history.section", defaultValue: "Clipboard History"),
                    contentSection: .history,
                    embeddedShortcutGroupIDs: [ShortcutID.primaryGroup, ShortcutID.collectionGroup]
                ),
                settingsSection(
                    id: SettingsSectionID.snippets,
                    title: localization.string("settings.snippets.section", defaultValue: "Snippets"),
                    contentSection: .snippets
                ),
                settingsSection(
                    id: SettingsSectionID.queue,
                    title: localization.string("hud.queue.explicit", defaultValue: "Paste Queue"),
                    contentSection: .queue,
                    embeddedShortcutGroupIDs: [ShortcutID.queueGroup]
                ),
                settingsSection(
                    id: SettingsSectionID.advanced,
                    title: localization.string("settings.advanced.title", defaultValue: "Advanced"),
                    contentSection: .advanced,
                    embeddedShortcutGroupIDs: [ShortcutID.panelGroup, ShortcutID.privacyGroup]
                ),
                settingsSection(
                    id: SettingsSectionID.data,
                    title: localization.string("settings.data.section", defaultValue: "Local Data"),
                    contentSection: .data
                ),
            ]
        )
    }

    private func settingsSection(
        id: String,
        title: String,
        contentSection: ClipboardHistorySettingsContentSection,
        embeddedShortcutGroupIDs: Set<String> = []
    ) -> PluginSettingsSection {
        PluginSettingsSection(
            id: id,
            title: title,
            presentation: .edgeToEdge,
            embeddedShortcutGroupIDs: embeddedShortcutGroupIDs
        ) { [weak self] context in
            if let self {
                ClipboardHistorySettingsView(
                    controller: self.controller,
                    savedLibraryController: self.savedLibraryController,
                    localization: self.localization,
                    settingsContext: context,
                    contentSections: [contentSection],
                    onManageSnippets: { [weak self] in
                        guard let self, !self.isBackingUpClipboard else { return }
                        self.panelController.showSnippets()
                    },
                    itemShortcutStore: self.itemShortcutStore,
                    onRemoveItemShortcut: { [weak self] itemID, format in
                        self?.removeItemShortcut(itemID: itemID, pasteFormat: format)
                    },
                    backupService: { [weak self] in
                        guard let self else { return nil }
                        return self.backupPersistence?.backupService(
                            maximumItemBytes: self.settingsStore.snapshot.maximumItemByteCount
                        )
                    },
                    onBackupSuspend: { [weak self] in self?.suspendForClipboardBackup() },
                    onBackupResume: { [weak self] restored in self?.resumeAfterClipboardBackup(restored: restored) },
                    provisionalSavedMetadataForBackup: { [weak self] in
                        self?.provisionalSavedMetadataForBackup() ?? [:]
                    }
                )
            } else {
                EmptyView()
            }
        }
    }

    var rowState: PluginPanelRowState {
        let subtitle: String
        if let errorMessage = controller.errorMessage {
            subtitle = errorMessage
        } else if !controller.isLoaded {
            subtitle = localization.string("panel.status.loading", defaultValue: "正在读取加密历史…")
        } else if settingsStore.isPaused {
            subtitle = localization.string("panel.status.paused", defaultValue: "收集已暂停")
        } else if controller.isIgnoringNextCopy {
            subtitle = localization.string("panel.status.ignoreNext", defaultValue: "下次复制不会保存")
        } else {
            subtitle = localization.format(
                "panel.status.count",
                defaultValue: "%d history items · %d saved",
                controller.historyItemCount,
                controller.savedItemCount + savedLibraryController.items.count
            )
        }
        return PluginPanelRowState(
            subtitle: subtitle,
            isOn: !settingsStore.isPaused && controller.isCollectionOperational,
            isEnabled: controller.isLoaded,
            isAvailable: true,
            detail: nil,
            errorMessage: controller.errorMessage
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] {
        [
            PluginPermissionRequirement(
                id: PermissionID.accessibility,
                kind: .accessibility,
                title: localization.string("permission.accessibility.title", defaultValue: "辅助功能"),
                description: localization.string(
                    "permission.accessibility.description",
                    defaultValue: "用于发送私密复制和粘贴快捷键，也用于将历史记录粘贴到之前的应用。"
                )
            )
        ]
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        let fixed: [PluginShortcutDefinition] = [
            PluginShortcutDefinition(
                id: ShortcutID.privateCopy,
                title: localization.string("shortcut.privateCopy.title", defaultValue: "私密复制"),
                description: localization.string(
                    "shortcut.privateCopy.description",
                    defaultValue: "复制当前选择，但不读取或保存这次剪贴板内容。"
                ),
                actionID: ShortcutID.privateCopy,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.privacyGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "“立即私密复制”一步复制当前选择；“忽略下一次复制”会等待之后的右键菜单或 Command-C，15 秒后自动取消。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.privateCopy.controlTitle",
                    defaultValue: "立即私密复制"
                ),
                settingsControlSystemImage: "keyboard"
            ),
            PluginShortcutDefinition(
                id: ShortcutID.ignoreNextCopy,
                title: localization.string("shortcut.ignoreNext.title", defaultValue: "忽略下一次复制"),
                description: localization.string(
                    "shortcut.ignoreNext.description",
                    defaultValue: "接下来一次剪贴板变化不会被读取或保存，15 秒后自动取消。"
                ),
                actionID: ShortcutID.ignoreNextCopy,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.privacyGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.group.description",
                    defaultValue: "“立即私密复制”一步复制当前选择；“忽略下一次复制”会等待之后的右键菜单或 Command-C，15 秒后自动取消。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.ignoreNext.controlTitle",
                    defaultValue: "忽略下一次复制"
                ),
                settingsControlSystemImage: "cursorarrow.click"
            ),
            PluginShortcutDefinition(
                id: ShortcutID.pastePlainText,
                title: localization.string(
                    "shortcut.pastePlain.title",
                    defaultValue: "以纯文本粘贴剪贴板"
                ),
                description: localization.string(
                    "shortcut.pastePlain.description",
                    defaultValue: "不打开历史记录，直接粘贴富文本的可见文字；当前剪贴板为图片时使用已识别的文字。"
                ),
                actionID: ShortcutID.pastePlainText,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.primaryGroup,
                settingsGroupTitle: localization.string(
                    "shortcut.pastePlain.groupTitle",
                    defaultValue: "纯文本粘贴快捷键"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.pastePlain.groupDescription",
                    defaultValue: "用一个快捷键直接粘贴富文本的可见文字或当前图片中已识别的文字，无需打开剪贴板历史。"
                ),
                settingsControlTitle: localization.string(
                    "shortcut.pastePlain.controlTitle",
                    defaultValue: "粘贴当前剪贴板为纯文本"
                ),
                settingsControlSystemImage: "textformat"
            ),
            PluginShortcutDefinition(
                id: ShortcutID.pasteSequentially,
                title: localization.string(
                    "shortcut.pasteSequentially.title",
                    defaultValue: "Paste Sequentially"
                ),
                description: localization.string(
                    "shortcut.pasteSequentially.description",
                    defaultValue: "Paste the next queued item, or start with a snapshot of recent history."
                ),
                actionID: ShortcutID.pasteSequentially,
                scope: .global,
                defaultBinding: ShortcutBinding(
                    keyCode: 9,
                    modifiers: [.option, .shift]
                ),
                isRequired: false,
                settingsGroupID: ShortcutID.queueGroup,
                settingsGroupTitle: localization.string(
                    "settings.queue.shortcuts.title",
                    defaultValue: "Sequential Paste"
                ),
                settingsGroupDescription: localization.string(
                    "shortcut.pasteSequentially.groupDescription",
                    defaultValue: "Paste recent entries one at a time; advanced queue controls are optional."
                ),
                settingsControlTitle: localization.string(
                    "shortcut.pasteSequentially.controlTitle",
                    defaultValue: "Paste Next Queue Item"
                ),
                settingsControlSystemImage: "list.number"
            ),
            panelShortcut(
                id: ShortcutID.panelCycleScope,
                title: localization.string(
                    "panel.shortcuts.cycleScope",
                    defaultValue: "Switch Scope"
                ),
                description: localization.string(
                    "panel.shortcuts.cycleScope.description",
                    defaultValue: "Switch between All, History, and Snippets; add Shift to go backward. Control-1 through Control-3 selects a scope directly."
                ),
                keyCode: 48,
                modifiers: [.control],
                systemImage: "rectangle.3.group"
            ),
            panelShortcut(
                id: ShortcutID.panelActions,
                title: localization.string("panel.shortcuts.actions", defaultValue: "Toggle Actions"),
                description: localization.string("panel.shortcuts.actions.description", defaultValue: "Open Actions or close it and return to the history search."),
                keyCode: 40,
                modifiers: [.command],
                systemImage: "command"
            ),
            panelShortcut(
                id: ShortcutID.panelEditSnippet,
                title: localization.string("saved.edit", defaultValue: "Edit Snippet"),
                description: localization.string("panel.shortcuts.editSnippet.description", defaultValue: "Edit the selected snippet while the Clipboard window is focused."),
                keyCode: 14,
                modifiers: [.command, .option],
                systemImage: "pencil"
            ),
            panelShortcut(
                id: ShortcutID.panelExport,
                title: localization.string("panel.shortcuts.export", defaultValue: "Export"),
                description: localization.string("panel.shortcuts.export.description", defaultValue: "Open export formats for the focused clipboard item."),
                keyCode: 14,
                modifiers: [.command],
                systemImage: "square.and.arrow.down"
            ),
            panelShortcut(
                id: ShortcutID.panelShare,
                title: localization.string("panel.shortcuts.share", defaultValue: "Share"),
                description: localization.string("panel.shortcuts.share.description", defaultValue: "Open the macOS share sheet for the current item or selection."),
                keyCode: 14,
                modifiers: [.command, .shift],
                systemImage: "square.and.arrow.up"
            ),
            panelShortcut(
                id: ShortcutID.panelSave,
                title: localization.string("panel.shortcuts.save", defaultValue: "Save or Unsave Clip"),
                description: localization.string("panel.shortcuts.save.description", defaultValue: "Toggle whether the focused captured item is kept in Saved."),
                keyCode: 35,
                modifiers: [.command],
                systemImage: "bookmark"
            ),
            panelShortcut(
                id: ShortcutID.panelDelete,
                title: localization.string("panel.shortcuts.delete", defaultValue: "Delete Item"),
                description: localization.string("panel.shortcuts.delete.description", defaultValue: "Delete the focused clipboard item without conflicting with text editing."),
                keyCode: 51,
                modifiers: [.command, .shift],
                systemImage: "trash"
            ),
            panelShortcut(
                id: ShortcutID.panelMultiSelect,
                title: localization.string("panel.shortcuts.multiSelect", defaultValue: "Select Multiple Items"),
                description: localization.string("panel.shortcuts.multiSelect.description", defaultValue: "Enter or leave multiple-selection mode."),
                keyCode: 37,
                modifiers: [.command],
                systemImage: "checklist"
            ),
            panelShortcut(
                id: ShortcutID.panelToggleSelection,
                title: localization.string("panel.selection.toggleFocused", defaultValue: "Mark or Unmark Item"),
                description: localization.string("panel.shortcuts.toggleSelection.description", defaultValue: "In multi-select mode, select or unselect the highlighted item, even while the search field is focused."),
                keyCode: 36,
                modifiers: [.command],
                systemImage: "checkmark.square"
            ),
            panelShortcut(
                id: ShortcutID.panelSelectAll,
                title: localization.string("panel.selection.selectAll", defaultValue: "Select All Visible"),
                description: localization.string(
                    "panel.shortcuts.selectAll.description",
                    defaultValue: "In multi-select mode, select every item currently shown without taking focus from search."
                ),
                keyCode: 0,
                modifiers: [.command, .option],
                systemImage: "checkmark.square.fill"
            ),
            panelShortcut(
                id: ShortcutID.panelCopyCombined,
                title: localization.string("panel.shortcuts.copyCombined", defaultValue: "Copy Combined Selection"),
                description: localization.string("panel.shortcuts.copyCombined.description", defaultValue: "Copy selected entries together in their selected order."),
                keyCode: 8,
                modifiers: [.command, .shift],
                systemImage: "doc.on.doc"
            ),
            panelShortcut(
                id: ShortcutID.panelPasteCombined,
                title: localization.string("panel.shortcuts.pasteCombined", defaultValue: "Paste Combined Selection"),
                description: localization.string("panel.shortcuts.pasteCombined.description", defaultValue: "Paste selected entries together in their selected order."),
                keyCode: 36,
                modifiers: [.command, .shift],
                systemImage: "arrow.right.doc.on.clipboard"
            ),
        ]
        return fixed + cachedItemShortcutDefinitions
    }

    private func panelShortcut(
        id: String,
        title: String,
        description: String,
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        systemImage: String
    ) -> PluginShortcutDefinition {
        PluginShortcutDefinition(
            id: id,
            title: title,
            description: description,
            actionID: id,
            scope: .whilePluginActive,
            defaultBinding: ShortcutBinding(keyCode: keyCode, modifiers: modifiers),
            isRequired: false,
            settingsGroupID: ShortcutID.panelGroup,
            settingsGroupTitle: localization.string(
                "panel.shortcuts.group",
                defaultValue: "Clipboard Window Shortcuts"
            ),
            settingsGroupDescription: localization.string(
                "panel.shortcuts.group.description",
                defaultValue: "These shortcuts work only while the Clipboard window is focused."
            ),
            settingsControlTitle: title,
            settingsControlSystemImage: systemImage
        )
    }

    static func defaultPanelShortcutBinding(_ id: String) -> ShortcutBinding? {
        switch id {
        case ShortcutID.panelCycleScope:
            ShortcutBinding(keyCode: 48, modifiers: [.control])
        case ShortcutID.panelActions:
            ShortcutBinding(keyCode: 40, modifiers: [.command])
        case ShortcutID.panelExport:
            ShortcutBinding(keyCode: 14, modifiers: [.command])
        case ShortcutID.panelEditSnippet:
            ShortcutBinding(keyCode: 14, modifiers: [.command, .option])
        case ShortcutID.panelShare:
            ShortcutBinding(keyCode: 14, modifiers: [.command, .shift])
        case ShortcutID.panelSave:
            ShortcutBinding(keyCode: 35, modifiers: [.command])
        case ShortcutID.panelDelete:
            ShortcutBinding(keyCode: 51, modifiers: [.command, .shift])
        case ShortcutID.panelMultiSelect:
            ShortcutBinding(keyCode: 37, modifiers: [.command])
        case ShortcutID.panelToggleSelection:
            ShortcutBinding(keyCode: 36, modifiers: [.command])
        case ShortcutID.panelSelectAll:
            ShortcutBinding(keyCode: 0, modifiers: [.command, .option])
        case ShortcutID.panelCopyCombined:
            ShortcutBinding(keyCode: 8, modifiers: [.command, .shift])
        case ShortcutID.panelPasteCombined:
            ShortcutBinding(keyCode: 36, modifiers: [.command, .shift])
        default:
            nil
        }
    }

    static let queueControlActionIDs = [
        ActionID.previousSequentialQueueItem,
        ActionID.skipSequentialQueueItem,
        ActionID.restartSequentialQueue,
        ActionID.cancelSequentialQueue,
    ]

    var shortcutSettingsGroups: [PluginShortcutSettingsGroupConfiguration] {
        [
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.primaryGroup,
                title: localization.string(
                    "settings.shortcuts.primary.title",
                    defaultValue: "主要快捷键"
                ),
                systemImage: "keyboard",
                actionIDs: [ActionID.openHistory],
                shortcutDefinitionIDs: [ShortcutID.pastePlainText],
                placementAfterSectionID: SettingsSectionID.history
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.queueGroup,
                title: localization.string(
                    "settings.queue.shortcuts.title",
                    defaultValue: "Sequential Paste Queue"
                ),
                description: localization.string(
                    "settings.queue.shortcuts.description",
                    defaultValue: "Assign Paste Next first. Advanced queue controls are optional and can be added later."
                ),
                systemImage: "list.number",
                actionIDs: Set(Self.queueControlActionIDs),
                shortcutDefinitionIDs: [ShortcutID.pasteSequentially],
                placementAfterSectionID: SettingsSectionID.queue
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.panelGroup,
                title: localization.string("panel.shortcuts.group", defaultValue: "Clipboard Window Shortcuts"),
                description: localization.string("panel.shortcuts.group.description", defaultValue: "These shortcuts work only while the Clipboard window is focused."),
                systemImage: "rectangle.and.hand.point.up.left",
                shortcutDefinitionIDs: [
                    ShortcutID.panelCycleScope,
                    ShortcutID.panelActions,
                    ShortcutID.panelEditSnippet,
                    ShortcutID.panelExport,
                    ShortcutID.panelShare,
                    ShortcutID.panelSave,
                    ShortcutID.panelDelete,
                    ShortcutID.panelMultiSelect,
                    ShortcutID.panelToggleSelection,
                    ShortcutID.panelSelectAll,
                    ShortcutID.panelCopyCombined,
                    ShortcutID.panelPasteCombined,
                ],
                placementAfterSectionID: SettingsSectionID.advanced
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.privacyGroup,
                title: localization.string(
                    "shortcut.group.title",
                    defaultValue: "敏感内容复制快捷键"
                ),
                systemImage: "eye.slash",
                shortcutDefinitionIDs: [ShortcutID.privateCopy, ShortcutID.ignoreNextCopy],
                placementAfterSectionID: SettingsSectionID.advanced
            ),
            PluginShortcutSettingsGroupConfiguration(
                id: ShortcutID.collectionGroup,
                title: localization.string(
                    "settings.shortcuts.collection.title",
                    defaultValue: "高级控制"
                ),
                description: localization.string(
                    "settings.shortcuts.collection.description",
                    defaultValue: "可选：控制收集状态或清除历史记录。"
                ),
                systemImage: "playpause",
                actionIDs: Set(Self.collectionControlActionIDs),
                placementAfterSectionID: SettingsSectionID.history
            ),
        ]
    }

    var shortcutDefinitionFirstSettingsGroupIDs: Set<String> {
        [ShortcutID.queueGroup]
    }

    static let collectionControlActionIDs = [
        ActionID.pauseCollection,
        ActionID.resumeCollection,
        ActionID.toggleCollection,
        ActionID.clearAllHistory,
    ]

    var collapsibleShortcutSettingsGroupIDs: Set<String> {
        [ShortcutID.panelGroup, ShortcutID.privacyGroup, ShortcutID.collectionGroup]
    }

    var collapsibleActionSettingsGroupIDs: Set<String> {
        [ShortcutID.queueGroup]
    }

    var actionDefinitions: [ActionDefinition] {
        [
            action(
                id: ActionID.openHistory,
                title: localization.string("action.open.title", defaultValue: "打开剪贴板历史"),
                description: localization.string(
                    "action.open.description",
                    defaultValue: "打开可搜索的本机剪贴板历史面板；再次按下全局快捷键可关闭。"
                ),
                systemImage: "clipboard"
            ),
            action(
                id: ActionID.previousSequentialQueueItem,
                title: localization.string("hud.queue.previous", defaultValue: "Previous Queue Item"),
                description: localization.string(
                    "action.queue.previous.description",
                    defaultValue: "Move the sequential paste queue to the previous item."
                ),
                systemImage: "chevron.backward"
            ),
            action(
                id: ActionID.skipSequentialQueueItem,
                title: localization.string("hud.queue.skip", defaultValue: "Skip Queue Item"),
                description: localization.string(
                    "action.queue.skip.description",
                    defaultValue: "Skip the next item without pasting it."
                ),
                systemImage: "forward.end"
            ),
            action(
                id: ActionID.restartSequentialQueue,
                title: localization.string("hud.queue.restart", defaultValue: "Restart Queue"),
                description: localization.string(
                    "action.queue.restart.description",
                    defaultValue: "Start the active paste queue again from its first item."
                ),
                systemImage: "backward.end"
            ),
            action(
                id: ActionID.cancelSequentialQueue,
                title: localization.string("hud.queue.cancel", defaultValue: "Cancel Queue"),
                description: localization.string(
                    "action.queue.cancel.description",
                    defaultValue: "Cancel the active sequential paste queue."
                ),
                systemImage: "xmark.circle"
            ),
            action(
                id: ActionID.pauseCollection,
                title: localization.string("action.pause.title", defaultValue: "暂停剪贴板历史"),
                description: localization.string("action.pause.description", defaultValue: "暂停保存之后复制的剪贴板项目。"),
                systemImage: "pause.circle",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.resumeCollection,
                title: localization.string("action.resume.title", defaultValue: "恢复剪贴板历史"),
                description: localization.string("action.resume.description", defaultValue: "恢复保存之后复制的剪贴板项目。"),
                systemImage: "play.circle",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.toggleCollection,
                title: localization.string("action.toggle.title", defaultValue: "切换剪贴板历史收集"),
                description: localization.string("action.toggle.description", defaultValue: "在暂停和恢复之间切换。"),
                systemImage: "playpause",
                capabilities: [.automatic, .background, .foregroundInteractive]
            ),
            action(
                id: ActionID.clearAllHistory,
                title: localization.string("action.clearAll.title", defaultValue: "清除全部剪贴板历史"),
                description: localization.string(
                    "action.clearAll.description",
                    defaultValue: "Permanently delete all History items without removing Saved items."
                ),
                systemImage: "trash.slash",
                risk: .confirmationRequired,
                confirmation: ActionConfirmation(
                    title: localization.string("clear.all.title", defaultValue: "清除全部剪贴板历史？"),
                    message: localization.string(
                        "clear.all.actionMessage",
                        defaultValue: "All History items will be permanently deleted. Saved items are not affected. This cannot be undone."
                    ) + "\n\n" + localization.string(
                        "queue.explicit.retentionNotice",
                        defaultValue: "An active explicit paste queue keeps its encrypted copies until the queue finishes or is canceled."
                    ),
                    confirmButtonTitle: localization.string("common.clearAll", defaultValue: "全部清除")
                )
            ),
        ]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        if isBackingUpClipboard { return .unavailable(localization.string("backup.busy", defaultValue: "请先完成剪贴板备份操作。")) }
        switch reference.key.actionID {
        case ActionID.openHistory:
            return controller.isLoaded
                ? .available
                : .unavailable(localization.string("availability.loading", defaultValue: "剪贴板历史仍在载入。"))
        case ActionID.restartSequentialQueue,
             ActionID.previousSequentialQueueItem,
             ActionID.skipSequentialQueueItem:
            if isSequentialQueueMutationLocked {
                return .unavailable(localization.string(
                    "availability.sequentialPaste.inProgress",
                    defaultValue: "Wait for the current sequential paste to finish."
                ))
            }
            // Queue-control shortcuts remain configurable even while a queue is inactive.
            // Invoking an inapplicable control is intentionally a no-op.
            return .available
        case ActionID.cancelSequentialQueue:
            return .available
        case ActionID.pauseCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.resumeCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.toggleCollection:
            if let message = collectionActionBlockingMessage() {
                return .unavailable(message)
            }
            return .available
        case ActionID.clearAllHistory:
            if controller.isClearingHistory {
                return .unavailable(localization.string(
                    "availability.clearInProgress",
                    defaultValue: "正在清除剪贴板历史。"
                ))
            }
            if let errorMessage = controller.errorMessage {
                return .unavailable(errorMessage)
            }
            return controller.items.isEmpty
                ? .unavailable(localization.string("availability.noItems", defaultValue: "没有可清除的记录。"))
                : .available
        default:
            return .unavailable(PluginKitLocalization.actionInvalidParameters)
        }
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        if isBackingUpClipboard {
            let message = localization.string("backup.busy", defaultValue: "请先完成剪贴板备份操作。")
            return ActionExecutionHandle { .failed(message: message) }
        }
        if [ActionID.pauseCollection, ActionID.resumeCollection, ActionID.toggleCollection]
            .contains(invocation.reference.key.actionID),
           let message = collectionActionBlockingMessage() {
            return ActionExecutionHandle { .failed(message: message) }
        }
        switch invocation.reference.key.actionID {
        case ActionID.openHistory:
            if invocation.source == .globalShortcut {
                panelController.handleGlobalShortcut()
            } else {
                panelController.show()
            }
        case ActionID.previousSequentialQueueItem:
            return sequentialControlActionHandle { coordinator in
                await coordinator.moveToPrevious()
            }
        case ActionID.skipSequentialQueueItem:
            return sequentialControlActionHandle { coordinator in
                await coordinator.skip()
            }
        case ActionID.restartSequentialQueue:
            return sequentialControlActionHandle { coordinator in
                await coordinator.restart()
            }
        case ActionID.cancelSequentialQueue:
            return ActionExecutionHandle { [weak self] in
                guard let self else { return .cancelled }
                cancelSequentialQueueCreation()
                cancelPendingSequentialPastes()
                sequentialHUDPreviewTask?.cancel()
                sequentialHUDPreviewTask = nil
                guard await sequentialPasteCoordinator.cancel() else {
                    showSequentialPersistenceFailure()
                    return .failed(message: localization.string(
                        "hud.sequentialPaste.persistenceFailed",
                        defaultValue: "The paste queue couldn’t be saved. Try again."
                    ))
                }
                synchronizeSequentialPasteProtection()
                sequentialPasteHUD.dismiss()
                return .succeeded()
            }
        case ActionID.pauseCollection:
            settingsStore.setPaused(true)
        case ActionID.resumeCollection:
            settingsStore.setPaused(false)
        case ActionID.toggleCollection:
            settingsStore.setPaused(!settingsStore.isPaused)
        case ActionID.clearAllHistory:
            let controller = controller
            let failureMessage = localization.string(
                "availability.clearInProgress",
                defaultValue: "正在清除剪贴板历史。"
            )
            return ActionExecutionHandle {
                let succeeded = await controller.clearAllHistory()
                return succeeded
                    ? .succeeded()
                    : .failed(message: controller.errorMessage ?? failureMessage)
            }
        default:
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionInvalidParameters)
            }
        }
        return ActionExecutionHandle { .succeeded() }
    }

    private func sequentialControlActionHandle(
        _ operation: @escaping @MainActor (ClipboardSequentialPasteCoordinator) async -> Bool
    ) -> ActionExecutionHandle {
        ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            guard !isSequentialQueueMutationLocked else { return .cancelled }
            guard let session = sequentialPasteCoordinator.session,
                  !session.isComplete else { return .succeeded() }
            guard await operation(sequentialPasteCoordinator) else {
                showSequentialPersistenceFailure()
                return .failed(message: localization.string(
                    "hud.sequentialPaste.persistenceFailed",
                    defaultValue: "The paste queue couldn’t be saved. Try again."
                ))
            }
            sequentialQueueDidChange()
            return .succeeded()
        }
    }

    func handleAction(_ action: PluginPanelAction) {
        guard !isBackingUpClipboard else { return }
        guard case let .invokeAction(controlID) = action, controlID == "execute" else { return }
        panelController.show()
    }

    func handleShortcutAction(id: String) {
        guard !isBackingUpClipboard else { return }
        switch id {
        case ShortcutID.privateCopy:
            guard privateCopyTask == nil, !controller.isIgnoringNextCopy else { return }
            let targetProcessIdentifier = frontmostProcessIdentifier()
            privateCopyGeneration &+= 1
            let generation = privateCopyGeneration
            privateCopyTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performPrivateCopy(targetProcessIdentifier: targetProcessIdentifier)
                guard !Task.isCancelled, self.privateCopyGeneration == generation else { return }
                self.privateCopyTask = nil
            }
        case ShortcutID.ignoreNextCopy:
            armIgnoreNextCopy()
        case ShortcutID.pastePlainText:
            let targetProcessIdentifier = frontmostProcessIdentifier()
            Task { @MainActor [weak self] in
                await self?.performPasteClipboardAsPlainText(
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }
        case ShortcutID.pasteSequentially:
            enqueueSequentialPaste(
                targetProcessIdentifier: frontmostProcessIdentifier()
            )
        default:
            guard let target = ClipboardItemShortcutStore.target(for: id) else { return }
            enqueueItemShortcutPaste(
                itemID: target.itemID, pasteFormat: target.pasteFormat,
                targetProcessIdentifier: frontmostProcessIdentifier()
            )
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        guard permissionID == PermissionID.accessibility else {
            return PluginPermissionState(isGranted: true, footnote: nil)
        }
        let isGranted = accessibilityTrusted()
        return PluginPermissionState(
            isGranted: isGranted,
            footnote: isGranted
                ? nil
                : localization.string(
                    "permission.accessibility.footnote",
                    defaultValue: "普通收集、搜索和复制不需要此权限；私密复制和所有自动粘贴快捷键需要。"
                )
        )
    }

    func handlePermissionAction(id: String) {
        guard id == PermissionID.accessibility else { return }
        _ = accessibilityRequester(true)
        synchronizeKeywordExpansion()
        onStateChange?()
    }

    func refreshDisplayTopology() {
        panelController.refreshDisplayTopology()
    }

    func refreshAccessibilityPermission() {
        synchronizeKeywordExpansion()
        onStateChange?()
    }

    private func invalidatePendingItemShortcutWork() {
        itemShortcutLifecycleGeneration &+= 1
        itemShortcutRequestGeneration.removeAll()
        itemShortcutTailTask?.cancel()
        itemShortcutTailTask = nil
    }

    func suspendForClipboardBackup() {
        guard !isBackingUpClipboard else { return }
        isBackingUpClipboard = true
        invalidatePendingItemShortcutWork()
        cancelPendingSequentialPastes()
        cancelSequentialQueueCreation()
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        sequentialPasteHUD.dismiss()
        panelController.close(restorePreviousApplication: false, discardsPreviews: true)
        keywordExpander.stop()
        controller.suspendForBackup()
        savedLibraryController.stop()
    }

    func resumeAfterClipboardBackup(restored: Bool) {
        guard isBackingUpClipboard else { return }
        isBackingUpClipboard = false
        isPanelPreparationPending = true
        // A dispatched private copy can arrive after the backup sheet closes.
        if let lease = privateCopyLeaseStore.load() {
            _ = controller.restorePrivateCopySuppression(lease)
        }
        controller.resumeAfterBackup(restored: restored)
        savedLibraryController.start()
        retryPendingShortcutSaveRollbacksWhenReady()
        synchronizeKeywordExpansion()
        preparePanelWhenReady()
        onStateChange?()
    }

    func activate(context: PluginRuntimeContext) {
        isPanelPreparationPending = true
        if let lease = privateCopyLeaseStore.load() {
            _ = controller.restorePrivateCopySuppression(lease)
        }
        controller.start()
        savedLibraryController.start()
        sequentialQueueRestoreTask?.cancel()
        sequentialQueueRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sequentialPasteCoordinator.restoreExplicitQueue()
            } catch is CancellationError {
                return
            } catch {
                showSequentialPersistenceFailure()
                return
            }
            guard !Task.isCancelled else { return }
            synchronizeSequentialPasteProtection()
        }
        synchronizeKeywordExpansion()
        preparePanelWhenReady()
    }

    private func preparePanelWhenReady() {
        guard !isBackingUpClipboard, isPanelPreparationPending,
              controller.isLoaded, savedLibraryController.isLoaded else { return }
        isPanelPreparationPending = false
        panelController.prepareForNextPresentation()
    }

    func deactivate(reason: PluginDeactivationReason) {
        invalidatePendingItemShortcutWork()
        if reason == .uninstalling {
            itemShortcutStore.removeAll()
            activeProvisionalShortcutSaves.removeAll()
            pendingShortcutSaveRollbacks.removeAll()
        }
        isPanelPreparationPending = false
        isBackingUpClipboard = false
        controller.cancelBackupSuspension()
        if reason == .uninstalling {
            // Establish the storage barrier before cancellation. A task already queued behind a
            // database operation will wake to an invalidated coordinator instead of recreating
            // the database or Keychain key after package cleanup.
            databaseAccess.invalidate()
        }
        privateCopyGeneration &+= 1
        privateCopyTask?.cancel()
        privateCopyTask = nil
        cancelPendingSequentialPastes()
        cancelSequentialQueueCreation()
        sequentialQueueRestoreTask?.cancel()
        sequentialQueueRestoreTask = nil
        if reason == .uninstalling {
            sequentialPasteCoordinator.prepareForStorageReset()
        } else {
            sequentialPasteCoordinator.invalidatePendingPersistence()
        }
        sequentialPasteCoordinator.resetImplicitQueueForExternalCopy()
        synchronizeSequentialPasteProtection()
        panelController.close(restorePreviousApplication: false, discardsPreviews: true)
        privacyHUDPresenter.dismiss()
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        sequentialPasteHUD.dismiss()
        keywordExpander.stop()
        snippetPasteboardReader.stopImmediately()
        controller.stop()
        if reason == .uninstalling {
            privateCopyLeaseStore.clear()
        }
        savedLibraryController.stop(invalidatePersistence: reason == .uninstalling)
    }

    func refresh() {
        guard !isBackingUpClipboard else { return }
        controller.settingsDidChange()
        controller.start()
        savedLibraryController.start()
        synchronizeKeywordExpansion()
    }

    private func synchronizeKeywordExpansion() {
        guard !isBackingUpClipboard else { keywordExpander.stop(); return }
        keywordExpander.onDiagnostic = { [weak settingsStore] diagnostic in
            settingsStore?.keywordExpansionDiagnostic = diagnostic
        }
        guard settingsStore.isKeywordExpansionEnabled else {
            settingsStore.keywordExpansionDiagnostic = nil
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.off)
            return
        }
        keywordExpander.updateItems()
        guard keywordExpander.hasConfiguredKeywords else {
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.noKeywords)
            return
        }
        guard accessibilityTrusted() else {
            keywordExpander.stop()
            settingsStore.setKeywordExpansionStatus(.accessibilityRequired)
            return
        }
        keywordExpansionStartAttemptCountForTesting += 1
        settingsStore.setKeywordExpansionStatus(keywordExpander.start() ? .ready : .unavailable)
    }

    func setKeywordExpansionEnabledForTesting(_ enabled: Bool) {
        settingsStore.isKeywordExpansionEnabled = enabled
    }

    func startSequentialQueueForTesting(itemIDs: [UUID]) async -> Bool {
        await requestSequentialQueueCreation(itemIDs: itemIDs)
    }

    private func performPrivateCopy(targetProcessIdentifier: pid_t?) async {
        guard controller.canSuppressNextCapture else {
            showClipboardUnavailableHUD()
            return
        }
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.privateCopy.accessibilityRequired",
                defaultValue: "私密复制需要辅助功能权限"
            ) })
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return
        }
        guard let targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.privateCopy.failed",
                defaultValue: "私密复制失败"
            ) })
            return
        }

        let sent = await copyCommandSender.sendCopyCommand(
            to: targetProcessIdentifier
        ) { [weak controller] in
            // There is no trustworthy completion acknowledgement after posting Command-C. Keep
            // suppression fail-closed until the pasteboard transition is consumed or the original
            // timeout expires; cancelling it after a short observation window can persist a slow
            // application's sensitive copy.
            return controller?.ignoreNextCopy(expiringAfter: 15, mode: .privateCopy) == true
        }
        guard !Task.isCancelled else {
            if privateCopyLeaseStore.load() == nil {
                controller.cancelNextCaptureSuppression()
            }
            return
        }
        guard sent else {
            let hadPendingSuppression = controller.isIgnoringNextCopy
            let mayHaveDispatchedCopy = privateCopyLeaseStore.load() != nil
            if !mayHaveDispatchedCopy {
                controller.cancelNextCaptureSuppression()
            }
            if !controller.canSuppressNextCapture {
                showClipboardUnavailableHUD()
            } else if !hadPendingSuppression {
                privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                    "hud.privateCopy.failed",
                    defaultValue: "私密复制失败"
                ) })
            }
            if !accessibilityTrusted() {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            return
        }
    }

    private func performPasteClipboardAsPlainText(targetProcessIdentifier: pid_t?) async {
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.pastePlain.accessibilityRequired",
                defaultValue: "纯文本粘贴需要辅助功能权限"
            ) })
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return
        }
        guard let targetProcessIdentifier,
              frontmostProcessIdentifier() == targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.pastePlain.failed",
                defaultValue: "无法粘贴纯文本"
            ) })
            return
        }
        switch await controller.rewriteCurrentClipboardAsPlainText() {
        case .succeeded:
            resetImplicitQueueForManualClipboardWrite()
            break
        case .imageTextRecognitionPending:
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "panel.imageText.pending",
                defaultValue: "正在识别文字…"
            ) })
            return
        case .imageTextUnavailable:
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "panel.imageText.unavailable",
                defaultValue: "未识别到文字"
            ) })
            return
        case .unavailable:
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.pastePlain.unavailable",
                defaultValue: "剪贴板中没有可粘贴的文本"
            ) })
            return
        }
        let preparedClipboardVersion = controller.currentPasteboardVersion
        guard await pasteCommandSender.sendPasteCommand(
            to: targetProcessIdentifier,
            expectedPasteboardVersion: preparedClipboardVersion,
            currentPasteboardVersion: { self.controller.currentPasteboardVersion }
        ) else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.pastePlain.failed",
                defaultValue: "无法粘贴纯文本"
            ) })
            if !accessibilityTrusted() {
                requestPermissionGuidance?(PermissionID.accessibility)
                onStateChange?()
            }
            return
        }
    }

    private func enqueueSequentialPaste(targetProcessIdentifier: pid_t?) {
        guard !isBackingUpClipboard else { return }
        guard pendingSequentialPasteTargets.count
                + (isSequentialPasteInFlight ? 1 : 0)
                < ClipboardSequentialPasteSession.maximumItemCount else {
            showSequentialPasteHUD()
            return
        }
        pendingSequentialPasteTargets.append(targetProcessIdentifier)
        startSequentialPasteWorkerIfNeeded()
    }

    private func startSequentialPasteWorkerIfNeeded() {
        guard sequentialPasteWorkerTask == nil,
              !pendingSequentialPasteTargets.isEmpty else { return }
        sequentialPasteWorkerGeneration &+= 1
        let generation = sequentialPasteWorkerGeneration
        sequentialPasteWorkerTask = Task { @MainActor [weak self] in
            await self?.drainSequentialPasteRequests(generation: generation)
        }
    }

    private func drainSequentialPasteRequests(generation: Int) async {
        var pastedAtLeastOneItem = false
        defer {
            if sequentialPasteWorkerGeneration == generation {
                if pastedAtLeastOneItem {
                    showSequentialPasteHUD()
                }
                sequentialPasteWorkerTask = nil
                startSequentialPasteWorkerIfNeeded()
            }
        }

        while sequentialPasteWorkerGeneration == generation,
              !Task.isCancelled,
              !pendingSequentialPasteTargets.isEmpty {
            let targetProcessIdentifier = pendingSequentialPasteTargets.removeFirst()
            isSequentialPasteInFlight = true
            let didPaste = await performSequentialPaste(
                targetProcessIdentifier: targetProcessIdentifier,
                workerGeneration: generation
            )
            // An old worker must not clear a newly started worker's reservations.
            guard isCurrentSequentialPasteWorker(generation: generation) else { return }
            isSequentialPasteInFlight = false
            guard didPaste else {
                pendingSequentialPasteTargets.removeAll()
                return
            }
            pastedAtLeastOneItem = true
        }
    }

    private func cancelPendingSequentialPastes() {
        sequentialPasteWorkerGeneration &+= 1
        pendingSequentialPasteTargets.removeAll()
        isSequentialPasteInFlight = false
        sequentialPasteWorkerTask?.cancel()
        sequentialPasteWorkerTask = nil
    }

    private func prepareForPermanentDeletion(itemIDs: Set<UUID>) async -> Bool {
        guard !itemIDs.isEmpty,
              let session = sequentialPasteCoordinator.session,
              session.source == .explicitQueue,
              !session.isComplete,
              !itemIDs.isDisjoint(with: session.itemIDs) else {
            return true
        }
        cancelSequentialQueueCreation()
        cancelPendingSequentialPastes()
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        guard await sequentialPasteCoordinator.cancel() else {
            showSequentialPersistenceFailure()
            return false
        }
        synchronizeSequentialPasteProtection()
        sequentialPasteHUD.dismiss()
        return true
    }

    var sequentialPasteSessionForTesting: ClipboardSequentialPasteSession? {
        sequentialPasteCoordinator.session
    }

    func prepareForPermanentDeletionForTesting(itemIDs: Set<UUID>) async -> Bool {
        await prepareForPermanentDeletion(itemIDs: itemIDs)
    }

    private func cancelSequentialQueueCreation() {
        sequentialQueueCreationGeneration &+= 1
        sequentialPasteCoordinator.cancelPendingExplicitQueueCreation()
        sequentialQueueCreationTask?.cancel()
        sequentialQueueCreationTask = nil
    }

    private func prepareForHistoryClear() {
        guard sequentialPasteCoordinator.session?.source != .explicitQueue else { return }
        cancelSequentialQueueCreation()
        cancelPendingSequentialPastes()
        sequentialPasteCoordinator.resetImplicitQueueForExternalCopy()
        synchronizeSequentialPasteProtection()
        sequentialPasteHUD.dismiss()
    }

    private func pruneItemShortcutsWhenReady() {
        itemShortcutStore.expireIfNeeded()
        guard !itemShortcutStore.assignments.isEmpty else { return }
        refreshItemShortcutContent()
        let didLoadHistory = controller.isLoaded && controller.didLoadItemsSuccessfully
        let didLoadSnippets = savedLibraryController.isLoaded
            && savedLibraryController.fatalErrorMessage == nil
        itemShortcutStore.removeMissingItems(
            historyIDs: didLoadHistory ? Set(shortcutHistoryItems.keys) : nil,
            savedIDs: didLoadHistory ? Set(shortcutHistoryItems.values.lazy.filter(\.isSaved).map(\.id)) : nil,
            snippetIDs: didLoadSnippets ? Set(shortcutSnippets.keys) : nil
        )
    }

    private func undoShortcutSaveWhenAvailable(id: UUID, metadata: ClipboardHistorySavedMetadata) async {
        guard !itemShortcutStore.assignments.contains(where: { $0.itemID == id && $0.source == .saved }) else {
            pendingShortcutSaveRollbacks.removeValue(forKey: id)
            return
        }
        if !isBackingUpClipboard && controller.isLoaded {
            await controller.undoShortcutSave(id: id, metadata: metadata)
        }
        if controller.items.first(where: { $0.id == id })?.savedMetadata == metadata {
            pendingShortcutSaveRollbacks[id] = metadata
        } else if pendingShortcutSaveRollbacks[id] == metadata {
            pendingShortcutSaveRollbacks.removeValue(forKey: id)
        }
    }

    private func retryPendingShortcutSaveRollbacksWhenReady() {
        guard !isBackingUpClipboard, controller.isLoaded,
              !pendingShortcutSaveRollbacks.isEmpty else { return }
        let rollbacks = pendingShortcutSaveRollbacks
        pendingShortcutSaveRollbacks.removeAll()
        for (id, metadata) in rollbacks {
            Task { @MainActor [weak self] in
                await self?.undoShortcutSaveWhenAvailable(id: id, metadata: metadata)
            }
        }
    }

    func provisionalSavedMetadataForBackup() -> [UUID: ClipboardHistorySavedMetadata] {
        var excluded = pendingShortcutSaveRollbacks.filter { id, _ in
            !itemShortcutStore.assignments.contains { $0.itemID == id && $0.source == .saved }
        }
        excluded.merge(activeProvisionalShortcutSaves) { _, active in active }
        return excluded
    }

    func assignItemShortcut(
        itemID: UUID,
        pasteFormat: ClipboardItemShortcutStore.PasteFormat = .original,
        lifetime: ClipboardItemShortcutStore.Lifetime?,
        binding: ShortcutBinding?
    ) async -> PluginShortcutRecordingResult {
        guard !isBackingUpClipboard else {
            return .rejected(localization.string("itemShortcut.busy", defaultValue: "Clipboard is busy"))
        }
        let requestKey = ItemShortcutRequestKey(itemID: itemID, pasteFormat: pasteFormat)
        let generation = (itemShortcutRequestGeneration[requestKey] ?? 0) &+ 1
        itemShortcutRequestGeneration[requestKey] = generation
        let lifecycleGeneration = itemShortcutLifecycleGeneration
        await waitForItemShortcutAssignmentSlot(itemID: itemID)
        var provisionalSaveMetadata: ClipboardHistorySavedMetadata?
        defer {
            if let provisionalSaveMetadata,
               activeProvisionalShortcutSaves[itemID] == provisionalSaveMetadata {
                activeProvisionalShortcutSaves.removeValue(forKey: itemID)
            }
            finishItemShortcutAssignment(itemID: itemID)
        }
        guard !isBackingUpClipboard,
              itemShortcutLifecycleGeneration == lifecycleGeneration,
              itemShortcutRequestGeneration[requestKey] == generation,
              !Task.isCancelled else {
            return .rejected(localization.string("itemShortcut.unavailable", defaultValue: "This item is unavailable"))
        }
        var source: ClipboardItemShortcutStore.Source
        let snapshot: ClipboardSequentialPasteSnapshot
        do {
            if let saved = savedLibraryController.items.first(where: { $0.id == itemID }) {
                defer { saved.discardCachedPayloadIfReloadable() }
                source = .snippet
                snapshot = ClipboardSequentialPasteSnapshot(
                    sourceItemID: itemID, payload: try await saved.loadPayloadAsync(),
                    expandsSnippetVariables: saved.isSnippet
                )
            } else if let history = controller.items.first(where: { $0.id == itemID }) {
                defer { history.discardCachedPayloadIfReloadable() }
                source = history.isSaved ? .saved : .history
                snapshot = ClipboardSequentialPasteSnapshot(
                    sourceItemID: itemID, payload: try await history.loadPayloadAsync(),
                    expandsSnippetVariables: false
                )
            } else {
                throw ClipboardHistoryPayloadAccessError.unavailable
            }
        } catch {
            return .rejected(localization.string(
                "itemShortcut.unavailable", defaultValue: "This item is unavailable"
            ))
        }
        let itemStillAvailable = switch source {
        case .history: controller.items.contains { $0.id == itemID }
        case .saved: controller.items.contains { $0.id == itemID && $0.isSaved }
        case .snippet: savedLibraryController.items.contains { $0.id == itemID }
        }
        guard !isBackingUpClipboard,
              itemShortcutLifecycleGeneration == lifecycleGeneration,
              itemShortcutRequestGeneration[requestKey] == generation,
              !Task.isCancelled,
              snapshot.payloadByteCount <= ClipboardSequentialPasteSession.maximumPayloadByteCount,
              itemStillAvailable else {
            return .rejected(localization.string("itemShortcut.unavailable", defaultValue: "This item is unavailable"))
        }
        let previous = itemShortcutStore.assignment(for: itemID, pasteFormat: pasteFormat)
        if pasteFormat == .plainText {
            guard source != .snippet,
                  let item = controller.items.first(where: { $0.id == itemID }),
                  ClipboardPlainTextConversion.isAvailable(for: item) else {
                return .rejected(localization.string(
                    "itemShortcut.plainTextUnavailable", defaultValue: "This item has no plain text to paste."
                ))
            }
            guard !snapshot.payload.hasSinglePlainTextRepresentation || previous != nil else {
                return .rejected(localization.string(
                    "itemShortcut.textOnly.description",
                    defaultValue: "This item contains only plain text, so one shortcut covers both paste styles."
                ))
            }
        }
        guard (binding != nil || previous != nil), (lifetime != nil || previous != nil) else {
            return .rejected(localization.string(
                "itemShortcut.recordFirst", defaultValue: "Record a shortcut first."
            ))
        }
        var automaticallySavedMetadata: ClipboardHistorySavedMetadata?
        if source == .history,
           lifetime == .untilRemoved || (lifetime == nil && previous?.expiresAt == nil) {
            switch await controller.saveForShortcutIfNeeded(id: itemID, onProvisionalSave: { metadata in
                provisionalSaveMetadata = metadata
                activeProvisionalShortcutSaves[itemID] = metadata
            }) {
            case .unavailable:
                return .rejected(localization.string(
                    "itemShortcut.unavailable", defaultValue: "This item is unavailable"
                ))
            case .alreadySaved:
                break
            case let .saved(metadata):
                automaticallySavedMetadata = metadata
            }
            guard !isBackingUpClipboard,
                  itemShortcutLifecycleGeneration == lifecycleGeneration,
                  itemShortcutRequestGeneration[requestKey] == generation,
                  !Task.isCancelled,
                  controller.items.contains(where: { $0.id == itemID && $0.isSaved }) else {
                if let automaticallySavedMetadata {
                    await undoShortcutSaveWhenAvailable(id: itemID, metadata: automaticallySavedMetadata)
                }
                return .rejected(localization.string(
                    "itemShortcut.unavailable", defaultValue: "This item is unavailable"
                ))
            }
            source = .saved
        }
        guard !isBackingUpClipboard,
              itemShortcutLifecycleGeneration == lifecycleGeneration else {
            return .rejected(localization.string("itemShortcut.unavailable", defaultValue: "This item is unavailable"))
        }
        let assignment = itemShortcutStore.assign(
            itemID: itemID, source: source, pasteFormat: pasteFormat, lifetime: lifetime
        )
        if let binding {
            let shortcutID = "\(Self.pluginID).shortcut.\(assignment.definitionID)"
            guard let context = inlineShortcutSettingsContextProvider?() else {
                if let previous { itemShortcutStore.restore(previous) }
                else { _ = itemShortcutStore.remove(itemID: itemID, pasteFormat: pasteFormat) }
                if let automaticallySavedMetadata {
                    await undoShortcutSaveWhenAvailable(id: itemID, metadata: automaticallySavedMetadata)
                }
                return .rejected(localization.string("itemShortcut.recordUnavailable", defaultValue: "Shortcut settings are unavailable."))
            }
            let result = context.recordShortcut(binding, for: shortcutID)
            if case .rejected = result {
                if let previous { itemShortcutStore.restore(previous) }
                else { _ = itemShortcutStore.remove(itemID: itemID, pasteFormat: pasteFormat) }
                if let automaticallySavedMetadata {
                    await undoShortcutSaveWhenAvailable(id: itemID, metadata: automaticallySavedMetadata)
                }
                return result
            }
        }
        onStateChange?()
        privacyHUDPresenter.showSuccess(localizedMessage: { [localization] in localization.string(
            "itemShortcut.assigned", defaultValue: "Item shortcut assigned"
        ) })
        return .accepted
    }

    func removeItemShortcut(itemID: UUID, pasteFormat: ClipboardItemShortcutStore.PasteFormat? = nil) {
        for format in pasteFormat.map({ [$0] }) ?? ClipboardItemShortcutStore.PasteFormat.allCases {
            let requestKey = ItemShortcutRequestKey(itemID: itemID, pasteFormat: format)
            itemShortcutRequestGeneration[requestKey, default: 0] &+= 1
        }
        guard itemShortcutStore.remove(itemID: itemID, pasteFormat: pasteFormat) else { return }
        privacyHUDPresenter.showSuccess(localizedMessage: { [localization] in localization.string(
            "itemShortcut.removed", defaultValue: "Item shortcut removed"
        ) })
    }

    private func waitForItemShortcutAssignmentSlot(itemID: UUID) async {
        if activeItemShortcutAssignments.insert(itemID).inserted {
            synchronizeItemShortcutRetention()
            return
        }
        await withCheckedContinuation { continuation in
            waitingItemShortcutAssignments[itemID, default: []].append(continuation)
        }
    }

    private func finishItemShortcutAssignment(itemID: UUID) {
        if var waiting = waitingItemShortcutAssignments[itemID], !waiting.isEmpty {
            let next = waiting.removeFirst()
            if waiting.isEmpty {
                waitingItemShortcutAssignments.removeValue(forKey: itemID)
            } else {
                waitingItemShortcutAssignments[itemID] = waiting
            }
            next.resume()
        } else {
            activeItemShortcutAssignments.remove(itemID)
            synchronizeItemShortcutRetention()
        }
    }

    private func synchronizeItemShortcutRetention() {
        controller.updateShortcutRetainedItemIDs(
            itemShortcutStore.activeHistoryItemIDs.union(activeItemShortcutAssignments)
        )
    }

    private func enqueueItemShortcutPaste(
        itemID: UUID,
        pasteFormat: ClipboardItemShortcutStore.PasteFormat,
        targetProcessIdentifier: pid_t?
    ) {
        guard !isBackingUpClipboard else { return }
        guard let assignment = itemShortcutStore.assignment(for: itemID, pasteFormat: pasteFormat) else { return }
        let lifecycleGeneration = itemShortcutLifecycleGeneration
        let previous = itemShortcutTailTask
        itemShortcutTailTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, !self.isBackingUpClipboard,
                  self.itemShortcutLifecycleGeneration == lifecycleGeneration,
                  self.itemShortcutStore.isCurrent(assignment.id, itemID: itemID) else { return }
            await self.performItemShortcutPaste(
                assignment, targetProcessIdentifier: targetProcessIdentifier,
                lifecycleGeneration: lifecycleGeneration
            )
        }
    }

    func waitForItemShortcutPasteForTesting() async {
        await itemShortcutTailTask?.value
    }

    private func performItemShortcutPaste(
        _ assignment: ClipboardItemShortcutStore.Assignment,
        targetProcessIdentifier: pid_t?,
        lifecycleGeneration: UInt64
    ) async {
        guard itemShortcutLifecycleGeneration == lifecycleGeneration, !Task.isCancelled else { return }
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.quickPaste.accessibilityRequired", defaultValue: "Quick Paste requires Accessibility permission"
            ) })
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return
        }
        guard let targetProcessIdentifier,
              itemShortcutLifecycleGeneration == lifecycleGeneration,
              frontmostProcessIdentifier() == targetProcessIdentifier,
              itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID),
              controller.isLoaded, savedLibraryController.isLoaded else { return }
        let snapshot: ClipboardSequentialPasteSnapshot
        let plainText: String?
        do {
            if assignment.source == .snippet {
                guard let item = savedLibraryController.items.first(where: { $0.id == assignment.itemID }) else {
                    removeItemShortcut(itemID: assignment.itemID)
                    return
                }
                defer { item.discardCachedPayloadIfReloadable() }
                snapshot = ClipboardSequentialPasteSnapshot(
                    sourceItemID: item.id, payload: try await item.loadPayloadAsync(),
                    expandsSnippetVariables: true
                )
                plainText = nil
            } else {
                guard let item = controller.items.first(where: { $0.id == assignment.itemID }),
                      assignment.source != .saved || item.isSaved else {
                    removeItemShortcut(itemID: assignment.itemID)
                    return
                }
                defer { item.discardCachedPayloadIfReloadable() }
                snapshot = ClipboardSequentialPasteSnapshot(
                    sourceItemID: item.id, payload: try await item.loadPayloadAsync(),
                    expandsSnippetVariables: false
                )
                plainText = assignment.pasteFormat == .plainText
                    ? ClipboardPlainTextConversion.text(for: item) : nil
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled, itemShortcutLifecycleGeneration == lifecycleGeneration,
               itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID) {
                privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                    "hud.quickPaste.unavailable", defaultValue: "Quick Paste item is unavailable"
                ) })
            }
            return
        }
        guard itemShortcutLifecycleGeneration == lifecycleGeneration, !Task.isCancelled else { return }
        if assignment.pasteFormat == .plainText && plainText == nil {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "itemShortcut.plainTextUnavailable", defaultValue: "This item has no plain text to paste."
            ) })
            return
        }
        guard snapshot.payloadByteCount <= ClipboardSequentialPasteSession.maximumPayloadByteCount else { return }
        let fileURLs = assignment.pasteFormat == .original ? snapshot.payload.fileURLs : []
        let filesAvailable = await Task.detached(priority: .userInitiated) {
            fileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }.value
        guard itemShortcutLifecycleGeneration == lifecycleGeneration, !Task.isCancelled else { return }
        guard filesAvailable, itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID), !Task.isCancelled else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.quickPaste.unavailable", defaultValue: "Quick Paste item is unavailable"
            ) })
            return
        }
        guard let prepared = await savedLibraryController.copyQueuedSnapshotForPaste(
            snapshot,
            plainText: plainText,
            canWrite: { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && !self.isBackingUpClipboard
                    && self.itemShortcutLifecycleGeneration == lifecycleGeneration
                    && self.itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID)
                    && self.frontmostProcessIdentifier() == targetProcessIdentifier
            }
        ) else {
            if itemShortcutLifecycleGeneration == lifecycleGeneration,
               itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID), !Task.isCancelled {
                privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                    "hud.quickPaste.failed", defaultValue: "Couldn’t paste Quick Paste item"
                ) })
            }
            return
        }
        guard itemShortcutLifecycleGeneration == lifecycleGeneration,
              itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID), !Task.isCancelled else { return }
        var cursorAccess: SystemClipboardSnippetPasteCursorAccess?
        var cursorContext: ClipboardSnippetPasteCursorContext?
        defer { cursorAccess?.stop() }
        if snapshot.expandsSnippetVariables,
           prepared.expansion.cursorUTF16OffsetFromEnd != nil,
           let access = SystemClipboardSnippetPasteCursorAccess(processIdentifier: targetProcessIdentifier),
           let selection = access.selection {
            cursorAccess = access
            cursorContext = ClipboardSnippetPasteCursorContext(selection: selection, expansion: prepared.expansion)
        }
        let didPaste = await pasteCommandSender.sendPasteCommand(to: targetProcessIdentifier) { [weak self] in
            guard let self, !Task.isCancelled, !self.isBackingUpClipboard,
                  self.itemShortcutLifecycleGeneration == lifecycleGeneration,
                  self.itemShortcutStore.isCurrent(assignment.id, itemID: assignment.itemID),
                  self.frontmostProcessIdentifier() == targetProcessIdentifier else { return false }
            return self.pasteboard.changeCount == prepared.pasteboardVersion
        }
        guard itemShortcutLifecycleGeneration == lifecycleGeneration, !Task.isCancelled else { return }
        guard didPaste else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.quickPaste.failed", defaultValue: "Couldn’t paste Quick Paste item"
            ) })
            return
        }
        if assignment.source == .snippet {
            savedLibraryController.recordSuccessfulUse(id: assignment.itemID)
        } else {
            controller.recordSuccessfulUse(id: assignment.itemID)
        }
        if let cursorAccess, let cursorContext {
            await cursorContext.apply(access: cursorAccess)
        }
        // Sending Command-V only dispatches the key event. Keep the serialized clipboard-write
        // lane occupied long enough for the destination to consume this payload before the next
        // item shortcut replaces it.
        try? await Task.sleep(for: sequentialPasteStabilizationDelay)
    }

    private func performSequentialPaste(
        targetProcessIdentifier: pid_t?,
        workerGeneration: Int
    ) async -> Bool {
        guard accessibilityTrusted() else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.sequentialPaste.accessibilityRequired",
                defaultValue: "Sequential paste requires Accessibility permission"
            ) })
            if !accessibilityRequester(true) {
                requestPermissionGuidance?(PermissionID.accessibility)
            }
            onStateChange?()
            return false
        }
        guard let targetProcessIdentifier,
              frontmostProcessIdentifier() == targetProcessIdentifier else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.sequentialPaste.failed",
                defaultValue: "Couldn’t paste the next clipboard item"
            ) })
            return false
        }
        let operation: ClipboardSequentialPasteOperation
        do {
            guard let next = try await sequentialPasteCoordinator.nextOperation(
                recentHistoryItemIDs: controller.recentItemIDsForSequentialPaste
            ) else {
                privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                    "hud.sequentialPaste.empty",
                    defaultValue: "No clipboard items are available to paste"
                ) })
                return false
            }
            operation = next
        } catch is CancellationError {
            return false
        } catch {
            showSequentialPersistenceFailure()
            return false
        }
        let itemID = operation.itemID
        let implicitClipboardVersion = sequentialPasteCoordinator.session?.source == .recentHistory
            ? pasteboard.changeCount : nil
        synchronizeSequentialPasteProtection()

        let preparedClipboardVersion: Int?
        var preparedSnippetExpansion: ClipboardSnippetExpansion?
        if operation.source == .explicitQueue, let snapshot = operation.snapshot {
            let prepared = await savedLibraryController.copyQueuedSnapshotForPaste(snapshot)
            preparedClipboardVersion = prepared?.pasteboardVersion
            preparedSnippetExpansion = snapshot.expandsSnippetVariables ? prepared?.expansion : nil
        } else if controller.items.contains(where: { $0.id == itemID }) {
            let didPreparePayload = await controller.preparePayloadForUse(id: itemID)
            guard isCurrentSequentialPasteWorker(generation: workerGeneration),
                  sequentialPasteCoordinator.session?.matches(operation) == true,
                  revalidateImplicitClipboardVersion(implicitClipboardVersion),
                  didPreparePayload else {
                return await markSequentialItemUnavailable(operation)
            }
            preparedClipboardVersion = await controller.copyItemForPaste(id: itemID) { [weak self] in
                guard let self else { return false }
                return self.isCurrentSequentialPasteWorker(generation: workerGeneration)
                    && self.sequentialPasteCoordinator.session?.matches(operation) == true
                    && self.revalidateImplicitClipboardVersion(implicitClipboardVersion)
            }
        } else if savedLibraryController.items.contains(where: { $0.id == itemID }) {
            // Resolve snippet variables at paste time so every queue step sees current values.
            let prepared = await savedLibraryController.copyForPaste(id: itemID)
            preparedClipboardVersion = prepared?.pasteboardVersion
            preparedSnippetExpansion = prepared?.expansion
        } else {
            return await markSequentialItemUnavailable(operation)
        }
        guard isCurrentSequentialPasteWorker(generation: workerGeneration),
              sequentialPasteCoordinator.session?.matches(operation) == true else {
            return false
        }
        guard let preparedClipboardVersion else {
            return await markSequentialItemUnavailable(operation)
        }
        var cursorAccess: SystemClipboardSnippetPasteCursorAccess?
        var cursorContext: ClipboardSnippetPasteCursorContext?
        defer { cursorAccess?.stop() }
        if let expansion = preparedSnippetExpansion,
           expansion.cursorUTF16OffsetFromEnd != nil,
           let access = SystemClipboardSnippetPasteCursorAccess(
               processIdentifier: targetProcessIdentifier
           ),
           let selection = access.selection {
            cursorAccess = access
            cursorContext = ClipboardSnippetPasteCursorContext(
                selection: selection,
                expansion: expansion
            )
        }
        let didSendPaste = await pasteCommandSender.sendPasteCommand(to: targetProcessIdentifier) { [weak self] in
            guard let self,
                  self.isCurrentSequentialPasteWorker(generation: workerGeneration),
                  self.sequentialPasteCoordinator.session?.matches(operation) == true else { return false }
            guard self.pasteboard.changeCount == preparedClipboardVersion else {
                self.resetImplicitQueueForManualClipboardWrite()
                return false
            }
            return true
        }
        guard didSendPaste else {
            synchronizeSequentialPasteProtection()
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.sequentialPaste.failed",
                defaultValue: "Couldn’t paste the next clipboard item"
            ) })
            return false
        }
        if savedLibraryController.items.contains(where: { $0.id == itemID }) {
            savedLibraryController.recordSuccessfulUse(id: itemID)
        } else if operation.source == .explicitQueue {
            // Snapshot writes bypass the history copy path that normally records usage.
            controller.recordSuccessfulUse(id: itemID)
        }
        // Commit the exact item that was actually sent before yielding for pacing. Session-bound
        // operations prevent a late completion from advancing a replaced or cancelled queue.
        // A successful paste command is irreversible. Commit it from a fresh task so cancelling
        // the shortcut worker (deactivation, a new external copy, or queue dismissal) cannot make
        // the next launch repeat content that the destination already received.
        let commitTask = Task { @MainActor [sequentialPasteCoordinator] in
            await sequentialPasteCoordinator.recordSuccessfulPaste(operation: operation)
        }
        guard await commitTask.value else {
            showSequentialPersistenceFailure()
            return false
        }
        guard isCurrentSequentialPasteWorker(generation: workerGeneration) else { return true }
        if let cursorAccess, let cursorContext {
            await cursorContext.apply(access: cursorAccess)
        }
        synchronizeSequentialPasteProtection()
        isSequentialPasteInFlight = false

        // Shortcut presses are buffered immediately, while clipboard replacement is paced so the
        // destination gets a reliable chance to consume the current payload first.
        try? await Task.sleep(for: sequentialPasteStabilizationDelay)
        return true
    }

    private var isSequentialQueueMutationLocked: Bool {
        isBackingUpClipboard || isSequentialPasteInFlight || !pendingSequentialPasteTargets.isEmpty
    }

    private func markSequentialItemUnavailable(
        _ operation: ClipboardSequentialPasteOperation
    ) async -> Bool {
        guard await sequentialPasteCoordinator.markCurrentUnavailable(operation: operation) else {
            showSequentialPersistenceFailure()
            return false
        }
        synchronizeSequentialPasteProtection()
        privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
            "hud.sequentialPaste.unavailable",
            defaultValue: "This queued item is no longer available"
        ) })
        return false
    }

    private func isCurrentSequentialPasteWorker(generation: Int) -> Bool {
        !isBackingUpClipboard && sequentialPasteWorkerGeneration == generation && !Task.isCancelled
    }

    private func synchronizeSequentialPasteProtection() {
        controller.updateSequentialPasteProtectedItemIDs(
            sequentialPasteCoordinator.protectedItemIDs()
        )
    }

    private func resetImplicitQueueForManualClipboardWrite() {
        // A request can be buffered before its first implicit session is created.
        guard sequentialPasteCoordinator.session?.source != .explicitQueue else { return }
        cancelPendingSequentialPastes()
        sequentialPasteCoordinator.resetImplicitQueueForExternalCopy()
        synchronizeSequentialPasteProtection()
    }

    private func revalidateImplicitClipboardVersion(_ expectedVersion: Int?) -> Bool {
        guard let expectedVersion else { return true }
        guard pasteboard.changeCount == expectedVersion else {
            // A copy may precede the polling callback while a payload is loading.
            resetImplicitQueueForManualClipboardWrite()
            return false
        }
        return true
    }

    @discardableResult
    private func requestSequentialQueueCreation(itemIDs: [UUID]) async -> Bool {
        guard !isBackingUpClipboard else { return false }
        guard sequentialQueueCreationTask == nil else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.queue.active",
                defaultValue: "Finish or cancel the current queue before creating another one"
            ) })
            return false
        }
        sequentialQueueCreationGeneration &+= 1
        let generation = sequentialQueueCreationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.startSequentialQueue(itemIDs: itemIDs)
        }
        sequentialQueueCreationTask = task
        let created = await task.value
        if sequentialQueueCreationGeneration == generation {
            sequentialQueueCreationTask = nil
        }
        return created
    }

    @discardableResult
    private func startSequentialQueue(itemIDs: [UUID]) async -> Bool {
        let historyItemsByID = Dictionary(uniqueKeysWithValues: controller.items.map { ($0.id, $0) })
        let savedItemsByID = Dictionary(uniqueKeysWithValues: savedLibraryController.items.map { ($0.id, $0) })
        let availableItemIDs = Set(historyItemsByID.keys).union(savedItemsByID.keys)
        guard !itemIDs.isEmpty, itemIDs.allSatisfy(availableItemIDs.contains) else {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.sequentialPaste.unavailable",
                defaultValue: "This queued item is no longer available"
            ) })
            return false
        }
        do {
            var snapshots: [ClipboardSequentialPasteSnapshot] = []
            snapshots.reserveCapacity(itemIDs.count)
            var totalPayloadByteCount = 0
            for itemID in itemIDs {
                try Task.checkCancellation()
                let payload: ClipboardHistoryPayload
                let expandsSnippetVariables: Bool
                let discardPayload: () -> Void
                if let item = historyItemsByID[itemID] {
                    payload = try await item.loadPayloadAsync()
                    expandsSnippetVariables = false
                    discardPayload = { item.discardCachedPayloadIfReloadable() }
                } else if let item = savedItemsByID[itemID] {
                    payload = try await item.loadPayloadAsync()
                    expandsSnippetVariables = item.isSnippet
                    discardPayload = { item.discardCachedPayloadIfReloadable() }
                } else {
                    throw ClipboardHistoryPayloadAccessError.unavailable
                }
                defer { discardPayload() }
                totalPayloadByteCount += payload.byteCount
                guard totalPayloadByteCount <= ClipboardSequentialPasteSession.maximumPayloadByteCount else {
                    throw ClipboardSequentialQueueError.exceedsMaximumPayloadByteCount(
                        maximum: ClipboardSequentialPasteSession.maximumPayloadByteCount
                    )
                }
                snapshots.append(ClipboardSequentialPasteSnapshot(
                    sourceItemID: itemID,
                    payload: payload,
                    expandsSnippetVariables: expandsSnippetVariables
                ))
            }
            try await sequentialPasteCoordinator.startExplicitQueue(snapshots: snapshots)
            cancelPendingSequentialPastes()
            synchronizeSequentialPasteProtection()
            let queuedItemCount = sequentialPasteCoordinator.session?.totalCount ?? 0
            privacyHUDPresenter.showSuccess(localizedMessage: { [localization] in localization.format(
                "hud.queue.created",
                defaultValue: "Queue ready · %lld items",
                queuedItemCount
            ) })
            showSequentialPasteHUD()
            return true
        } catch ClipboardSequentialQueueError.activeQueueExists {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
                "hud.queue.active",
                defaultValue: "Finish or cancel the current queue before creating another one"
            ) })
        } catch ClipboardSequentialQueueError.exceedsMaximumItemCount {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.format(
                "hud.queue.tooMany",
                defaultValue: "A queue can contain up to %lld items",
                ClipboardSequentialPasteSession.maximumItemCount
            ) })
        } catch ClipboardSequentialQueueError.exceedsMaximumPayloadByteCount {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.format(
                "hud.queue.tooLarge",
                defaultValue: "A queue can contain up to %lld MB of clipboard data",
                ClipboardSequentialPasteSession.maximumPayloadByteCount / 1_024 / 1_024
            ) })
        } catch is CancellationError {
            return false
        } catch {
            privacyHUDPresenter.showFailure(localizedMessage: { [localization] in
                itemIDs.isEmpty ? localization.string(
                    "hud.queue.empty",
                    defaultValue: "Select at least one item for the queue"
                )
                : localization.string(
                    "hud.sequentialPaste.unavailable",
                    defaultValue: "This queued item is no longer available"
                )
            })
        }
        return false
    }

    private func sequentialQueueDidChange() {
        synchronizeSequentialPasteProtection()
        showSequentialPasteHUD()
    }

    private func showSequentialPersistenceFailure() {
        privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
            "hud.sequentialPaste.persistenceFailed",
            defaultValue: "The paste queue couldn’t be saved. Try again."
        ) })
    }

    private func showSequentialPasteHUD() {
        sequentialHUDPreviewTask?.cancel()
        sequentialHUDPreviewTask = nil
        guard !isBackingUpClipboard else {
            sequentialPasteHUD.dismiss()
            return
        }
        guard let session = sequentialPasteCoordinator.session else {
            sequentialPasteHUD.dismiss()
            return
        }
        guard !session.isComplete else {
            sequentialPasteHUD.showCompletion(
                source: session.source,
                dismissAfter: settingsStore.sequentialHUDDismissal.interval
            )
            return
        }
        let justPastedID = session.cursor > 0 ? session.itemIDs[session.cursor - 1] : nil
        let nextID = session.nextItemID
        let content = makeSequentialHUDContent(
            session: session,
            justPastedID: justPastedID,
            nextID: nextID,
            justPastedPreviewImageData: nil,
            nextPreviewImageData: nil
        )
        sequentialPasteHUD.show(
            content,
            dismissAfter: settingsStore.sequentialHUDDismissal.interval
        )

        guard !settingsStore.hidesSequentialHUDPreview else { return }
        let expectedCursor = session.cursor
        sequentialHUDPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let justPastedPreview = self.loadItemPreviewImageData(id: justPastedID)
            async let nextPreview = self.loadItemPreviewImageData(id: nextID)
            let loadedPreviews = await (justPastedPreview, nextPreview)
            guard !Task.isCancelled,
                  let currentSession = self.sequentialPasteCoordinator.session,
                  currentSession.cursor == expectedCursor,
                  currentSession.itemIDs == session.itemIDs else { return }
            let updatedContent = self.makeSequentialHUDContent(
                session: currentSession,
                justPastedID: justPastedID,
                nextID: nextID,
                justPastedPreviewImageData: loadedPreviews.0,
                nextPreviewImageData: loadedPreviews.1
            )
            self.sequentialPasteHUD.updateContentIfVisible(updatedContent)
        }
    }

    private func makeSequentialHUDContent(
        session: ClipboardSequentialPasteSession,
        justPastedID: UUID?,
        nextID: UUID?,
        justPastedPreviewImageData: Data?,
        nextPreviewImageData: Data?
    ) -> ClipboardSequentialPasteHUDContent {
        ClipboardSequentialPasteHUDContent(
            source: session.source,
            justPastedTitle: itemTitle(id: justPastedID),
            nextTitle: itemTitle(id: nextID),
            justPastedPreviewImageData: justPastedPreviewImageData,
            nextPreviewImageData: nextPreviewImageData,
            position: max(1, session.currentPosition ?? session.totalCount),
            totalCount: session.totalCount,
            hidesPreview: settingsStore.hidesSequentialHUDPreview,
            isComplete: false
        )
    }

    private func itemTitle(id: UUID?) -> String? {
        guard let id else { return nil }
        if let savedItem = savedLibraryController.items.first(where: { $0.id == id }) {
            return String(savedItem.title.prefix(100))
        }
        guard let item = controller.items.first(where: { $0.id == id }) else { return nil }
        let rawTitle = item.text.isEmpty
            ? Self.localizedContentKindTitle(item.kind, localization: localization)
            : item.text
        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(100))
    }

    private func refreshItemShortcutContent() {
        let itemIDs = Set(itemShortcutStore.assignments.map(\.itemID))
        let revision = ItemShortcutContentRevision(history: controller.presentationRevision,
                                                   snippets: savedLibraryController.presentationRevision,
                                                   itemIDs: itemIDs)
        guard revision != itemShortcutContentRevision else { return }
        itemShortcutContentRevision = revision
        shortcutHistoryItems.removeAll(keepingCapacity: !itemIDs.isEmpty)
        shortcutSnippets.removeAll(keepingCapacity: !itemIDs.isEmpty)
        guard !itemIDs.isEmpty else { return }
        // Retain only assigned targets, and share this lookup between pruning and
        // title construction. Status-only controller updates need no history scan.
        for item in controller.items where itemIDs.contains(item.id) {
            shortcutHistoryItems[item.id] = item
        }
        for item in savedLibraryController.items where itemIDs.contains(item.id) {
            shortcutSnippets[item.id] = item
        }
    }

    private func refreshItemShortcutDefinitions() {
        refreshItemShortcutContent()
        let originalAssignmentItemIDs = Set(itemShortcutStore.assignments.lazy
            .filter { $0.pasteFormat == .original }
            .map(\.itemID))

        cachedItemShortcutDefinitions = itemShortcutStore.assignments.map { assignment in
            let item = shortcutHistoryItems[assignment.itemID]
            let name = itemShortcutTitle(item: item, snippet: shortcutSnippets[assignment.itemID])
            let isTextOnly = assignment.source == .snippet || item?.isPlainTextOnly == true
            let isLegacyDuplicate = isTextOnly && assignment.pasteFormat == .plainText
                && originalAssignmentItemIDs.contains(assignment.itemID)
            let formatName: String
            if isTextOnly && !isLegacyDuplicate {
                formatName = localization.string("itemShortcut.format.textOnly", defaultValue: "Paste Text")
            } else if assignment.pasteFormat == .plainText {
                formatName = localization.string("itemShortcut.format.plainText", defaultValue: "Paste as Plain Text")
            } else {
                formatName = localization.string("itemShortcut.format.original", defaultValue: "Paste Original")
            }
            let formatDescription: String
            if isTextOnly {
                formatDescription = isLegacyDuplicate
                    ? localization.string(
                        "itemShortcut.textOnly.existingPlain",
                        defaultValue: "This existing shortcut pastes the same text. You can keep or remove it."
                    )
                    : localization.string(
                        "itemShortcut.textOnly.description",
                        defaultValue: "This item contains only plain text, so one shortcut covers both paste styles."
                    )
            } else if assignment.pasteFormat == .plainText {
                formatDescription = localization.string(
                    "itemShortcut.format.plainText.description",
                    defaultValue: "Pastes text only, without formatting or other data. Images use recognized text; files use paths."
                )
            } else {
                formatDescription = localization.string(
                    "itemShortcut.format.original.description",
                    defaultValue: "Preserves formatting and other original clipboard data."
                )
            }
            return PluginShortcutDefinition(
                id: assignment.definitionID,
                title: "\(name) — \(formatName)",
                description: formatDescription,
                actionID: assignment.definitionID,
                scope: .global,
                defaultBinding: nil,
                isRequired: false,
                settingsGroupID: ShortcutID.primaryGroup,
                settingsGroupTitle: localization.string("settings.shortcuts.primary.title", defaultValue: "Main Shortcuts"),
                settingsControlTitle: "\(name) — \(formatName)",
                settingsControlSystemImage: "pin"
            )
        }
    }

    private func itemShortcutTitle(
        item: ClipboardHistoryItem?,
        snippet: ClipboardSavedItem?
    ) -> String {
        if let snippet {
            return String(snippet.title.prefix(80))
        }
        guard let item else {
            return localization.string("quickPaste.historyItem", defaultValue: "History item")
        }
        if let savedTitle = item.savedMetadata?.title, !savedTitle.isEmpty {
            return String(savedTitle.prefix(80))
        }
        let rawTitle = item.text.isEmpty
            ? Self.localizedContentKindTitle(item.kind, localization: localization)
            : item.text
        let normalizedTitle = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = normalizedTitle.isEmpty
            ? localization.string("quickPaste.historyItem", defaultValue: "History item")
            : normalizedTitle
        return "\(String(preview.prefix(60))) · \(item.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(PluginRuntimeLocalization.locale)))"
    }

    private static func localizedContentKindTitle(
        _ kind: ClipboardHistoryContentKind,
        localization: PluginLocalization
    ) -> String {
        switch kind {
        case .plainText:
            localization.string("content.kind.text", defaultValue: "Text")
        case .richText:
            localization.string("content.kind.richText", defaultValue: "Rich Text")
        case .image:
            localization.string("content.kind.image", defaultValue: "Image")
        case .pdf:
            localization.string("content.kind.pdf", defaultValue: "PDF")
        case .files:
            localization.string("content.kind.files", defaultValue: "Files")
        case .link:
            localization.string("content.kind.link", defaultValue: "Link")
        case .color:
            localization.string("content.kind.color", defaultValue: "Color")
        case .media:
            localization.string("content.kind.media", defaultValue: "Media")
        }
    }

    private func loadItemPreviewImageData(id: UUID?) async -> Data? {
        guard let id else { return nil }
        let payload: ClipboardHistoryPayload
        let discardPayload: () -> Void
        if let item = controller.items.first(where: { $0.id == id }),
           item.filterContentKinds.contains(.image),
           let loaded = try? await item.loadPayloadAsync() {
            payload = loaded
            discardPayload = { item.discardCachedPayloadIfReloadable() }
        } else if let item = savedLibraryController.items.first(where: { $0.id == id }),
                  item.contentKind == .image,
                  let loaded = try? await item.loadPayloadAsync() {
            payload = loaded
            discardPayload = { item.discardCachedPayloadIfReloadable() }
        } else {
            return nil
        }
        let worker = Task.detached(priority: .utility) { () -> Data? in
            guard !Task.isCancelled,
                  let data = payload.representations.first(where: {
                      ClipboardRepresentationType.isImage($0.typeIdentifier)
                  })?.data else { return nil }
            return Self.makeHUDThumbnailData(from: data)
        }
        let imageData = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        discardPayload()
        return imageData
    }

    nonisolated static func makeHUDThumbnailData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              ClipboardEmbeddedPreviewPolicy.allowsImageSourceDimensions(
                  width: width.intValue,
                  height: height.intValue
              ),
              !Task.isCancelled,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary
              ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func armIgnoreNextCopy() {
        guard controller.ignoreNextCopy() else {
            showClipboardUnavailableHUD()
            return
        }
    }

    private func showClipboardUnavailableHUD() {
        privacyHUDPresenter.showFailure(localizedMessage: { [localization] in localization.string(
            "hud.clipboardUnavailable",
            defaultValue: "剪贴板历史尚未准备好"
        ) })
    }

    private func collectionActionBlockingMessage() -> String? {
        if let errorMessage = controller.errorMessage {
            return errorMessage
        }
        guard controller.isLoaded else {
            return localization.string(
                "availability.loading",
                defaultValue: "剪贴板历史仍在载入。"
            )
        }
        guard !controller.isClearingHistory else {
            return localization.string(
                "availability.clearInProgress",
                defaultValue: "正在清除剪贴板历史。"
            )
        }
        guard controller.isCollectionOperational else {
            return localization.string(
                "availability.collectionUnavailable",
                defaultValue: "剪贴板历史收集目前不可用。"
            )
        }
        return nil
    }

    private func action(
        id: String,
        title: String,
        description: String,
        systemImage: String,
        risk: ActionRisk = .safe,
        confirmation: ActionConfirmation? = nil,
        capabilities: ActionExecutionCapabilities = [.foregroundInteractive]
    ) -> ActionDefinition {
        ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: id),
            title: title,
            description: description,
            keywords: [
                localization.string("action.keyword.clipboard", defaultValue: "剪贴板"),
                "clipboard",
                "history",
                title,
            ],
            systemImage: systemImage,
            risk: risk,
            confirmation: confirmation,
            externalInvocationPolicy: .unavailable,
            capabilities: capabilities
        )
    }

    private static func localizedErrorMessage(
        _ error: Error,
        localization: PluginLocalization
    ) -> String {
        if let templateError = error as? ClipboardSnippetTemplateError {
            return templateError.localizedMessage(localization)
        }
        if let savedError = error as? ClipboardSavedLibraryError {
            switch savedError {
            case let .duplicateKeyword(keyword):
                return localization.format(
                    "saved.error.duplicateKeyword",
                    defaultValue: "The keyword %@ is already assigned to another snippet.",
                    keyword
                )
            case .invalidKeyword:
                return localization.string(
                    "saved.error.invalidKeyword",
                    defaultValue: "A keyword cannot contain spaces or line breaks."
                )
            case let .snippetTooLarge(maximumByteCount):
                return localization.format(
                    "saved.error.snippetTooLarge",
                    defaultValue: "A snippet cannot exceed %@.",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(maximumByteCount),
                        countStyle: .file
                    )
                )
            case let .keywordExpansionCacheFull(maximumByteCount):
                return localization.format(
                    "saved.error.keywordCacheFull",
                    defaultValue: "Keyword-enabled snippets cannot exceed %@ in total.",
                    ByteCountFormatter.string(
                        fromByteCount: Int64(maximumByteCount),
                        countStyle: .file
                    )
                )
            case .plainTextUnavailable:
                return localization.string(
                    "saved.error.plainTextUnavailable",
                    defaultValue: "This saved item doesn’t contain pasteable text."
                )
            }
        }
        guard let storeError = error as? ClipboardHistoryStoreError else {
            return error.localizedDescription
        }
        switch storeError {
        case .missingEncryptionKey:
            return localization.string(
                "error.missingEncryptionKey",
                defaultValue: "找不到剪贴板历史的加密密钥。历史记录已停止收集。"
            )
        case .invalidEncryptionKey:
            return localization.string(
                "error.invalidEncryptionKey",
                defaultValue: "剪贴板历史的加密密钥无效。历史记录已停止收集。"
            )
        case .invalidEnvelope:
            return localization.string(
                "error.invalidEnvelope",
                defaultValue: "无法读取剪贴板历史。原始加密数据已保留。"
            )
        case .authenticationFailed:
            return localization.string(
                "error.authenticationFailed",
                defaultValue: "无法验证剪贴板历史。原始加密数据已保留。"
            )
        case .historyTooLarge:
            return localization.string(
                "error.historyTooLarge",
                defaultValue: "剪贴板历史超过安全存储上限。请清除现有历史记录。"
            )
        case .insufficientDiskSpace:
            return localization.string(
                "error.insufficientDiskSpace",
                defaultValue: "可用磁盘空间不足，无法保存新的剪贴板历史。"
            )
        case .unavailableStorage:
            return localization.string(
                "error.unavailableStorage",
                defaultValue: "无法使用剪贴板历史的专用存储空间。"
            )
        case .keychain:
            return localization.string(
                "error.keychain",
                defaultValue: "无法访问用于保护剪贴板历史的钥匙串密钥。"
            )
        }
    }
}
