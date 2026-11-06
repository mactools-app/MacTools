import AppKit
import MacToolsPluginKit
import XCTest
@testable import ClipboardHistoryPlugin

@MainActor
final class ClipboardHistoryFiltersTests: XCTestCase {
    func testSavedOnlyIntersectsScopesAndClearPreservesScopeAndQuery() async {
        var saved = item(text: "saved clip")
        saved.setSavedMetadata(.init(title: "Saved", savedAt: .now))
        let snippet = ClipboardSavedItem(title: "Template", savedKind: .snippet,
            payload: .plainText("template"), templateText: "template")
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [saved, item(text: "ordinary clip")], savedItems: [snippet])
        model.applyFilter(.savedOnly(true))
        await model.waitForSearchForTesting()
        XCTAssertEqual(Set(model.visibleItems.map(\.id)), [saved.id, snippet.id])
        model.applyFilter(.scope(.history))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [saved.id])
        model.applyFilter(.scope(.snippets))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
        model.query = "template"
        model.applyFilter(.clear)
        XCTAssertEqual(model.mode, .snippets)
        XCTAssertEqual(model.query, "template")
        XCTAssertFalse(model.filters.hasSecondaryFilters)
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [snippet.id])
    }

    func testColdAndCachedOpeningsRestoreAllAxesBeforeResultsBecomeActionable() async {
        var image = makeImage()
        image.setSavedMetadata(.init(title: "Image", savedAt: .now))
        let items = [item(text: "text"), image]
        let filters = ClipboardHistoryFilterState(scope: .history, type: .image, savedOnly: true)
        for preparation in ["cold", "cached", "prewarm"] {
            let model = ClipboardHistoryPanelModel()
            if preparation == "cached" {
                model.prepareForPresentation(items: items, historyRevision: 1, savedRevision: 1)
                await model.waitForSearchForTesting()
            } else if preparation == "prewarm" {
                model.prepareForPresentationAsynchronously(items: items, historyRevision: 1, savedRevision: 1)
            }
            var rememberedWrites = 0
            model.onUserFilterChange = { _ in rememberedWrites += 1 }
            model.prepareForPresentationAsynchronously(items: items, historyRevision: 1, savedRevision: 1,
                                                       initialFilters: filters)
            XCTAssertEqual(model.filters, filters)
            XCTAssertFalse(model.canPasteCurrentResults)
            model.requestActionMenu()
            await model.waitForPresentationPreparationForTesting()
            await model.waitForSearchForTesting()
            XCTAssertTrue(model.isActionPalettePresented, "Preparation must preserve independently opened filter actions")
            XCTAssertEqual(model.filters, filters)
            XCTAssertEqual(model.visibleItems.map(\.id), [image.id])
            XCTAssertTrue(model.canPasteCurrentResults)
            XCTAssertEqual(rememberedWrites, 0, "Preparation cannot replace remembered user intent")
        }
    }

    func testExplicitSnippetOpeningPreservesRememberedIntentAcrossRestart() async {
        let storage = FilterSettingsStorage()
        let settings = ClipboardHistorySettingsStore(storage: storage)
        let remembered = ClipboardHistoryFilterState(scope: .history, type: .image)
        settings.setRemembersPanelFilters(true, current: remembered)
        let restarted = ClipboardHistorySettingsStore(storage: storage)
        XCTAssertEqual(restarted.panelFiltersForOpening(), remembered)
        XCTAssertEqual(restarted.panelFiltersForOpening(explicitScope: .snippets), .init(scope: .snippets))
        let model = ClipboardHistoryPanelModel()
        model.onUserFilterChange = { restarted.recordPanelFilters($0) }
        model.prepareForPresentationAsynchronously(items: [],
            initialFilters: restarted.panelFiltersForOpening(explicitScope: .snippets))
        await model.waitForPresentationPreparationForTesting()
        await model.waitForSearchForTesting()
        XCTAssertEqual(restarted.panelFiltersForOpening(), remembered)
        model.applyFilter(.type(.text))
        XCTAssertEqual(ClipboardHistorySettingsStore(storage: storage).openingPanelFilters,
                       .init(scope: .snippets, type: .text))
        model.selectScope(at: 1)
        XCTAssertEqual(restarted.openingPanelFilters.scope, .history)
        model.cycleScope()
        XCTAssertEqual(restarted.openingPanelFilters.scope, .snippets)
        restarted.setRemembersPanelFilters(false, current: model.filters)
        XCTAssertEqual(ClipboardHistorySettingsStore(storage: storage).openingPanelFilters, .defaults)
        restarted.setRemembersPanelFilters(true, current: .defaults)
        XCTAssertEqual(restarted.openingPanelFilters, .defaults, "Enabling again cannot resurrect old filters")
    }

    func testPendingFilterResultsRejectOldItemActionsAndPasteSelection() async throws {
        let text = item(text: "text")
        let image = makeImage()
        let model = ClipboardHistoryPanelModel()
        model.prepareForPresentation(items: [text, image])
        model.selectedItemID = text.id
        let context = try XCTUnwrap(model.actionContext)
        XCTAssertTrue(model.canPasteCurrentResults)
        model.applyFilter(.type(.image))
        XCTAssertFalse(model.canPasteCurrentResults)
        XCTAssertFalse(model.canPerformAction(in: context))
        await model.waitForSearchForTesting()
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])
        XCTAssertEqual(model.selectedItemID, image.id)
        XCTAssertTrue(model.canPasteCurrentResults)
        XCTAssertFalse(model.canPerformAction(in: context))
    }

    func testFilterChangesKeepMatchingFocusBeyondTheFirstPageForClipsAndSnippets() async throws {
        for snippets in [false, true] {
            let model = ClipboardHistoryPanelModel()
            let count = ClipboardHistoryPanelModel.resultPageSize + 2
            if snippets {
                let items = (0..<count).map { index in
                    ClipboardSavedItem(title: "Template \(index)", savedKind: .snippet,
                        payload: .plainText("template"), templateText: "template")
                }
                model.prepareForPresentation(items: [], savedItems: items, initialFilters: .init(scope: .snippets))
            } else {
                model.prepareForPresentation(items: (0..<count).map { item(text: "clip \($0)") })
            }
            model.loadMoreResults()
            await model.waitForSearchForTesting()
            let initialFocus = try XCTUnwrap(model.visibleItems.last?.id)
            let focusedID = try XCTUnwrap(model.visibleItems.dropLast().last?.id)
            model.selectedItemID = initialFocus
            model.applyFilter(.type(.text))
            model.selectedItemID = focusedID
            await model.waitForSearchForTesting()
            XCTAssertEqual(model.selectedItemID, focusedID)
            XCTAssertTrue(model.visibleItems.contains { $0.id == focusedID })
            if snippets { XCTAssertNotNil(model.savedItem(forPresentationID: focusedID)) }
            let context = model.actionContext
            model.applyFilter(.type(.text))
            XCTAssertTrue(model.canPasteCurrentResults, "Reselecting a filter cannot invalidate unchanged results")
            XCTAssertEqual(model.actionContext, context)
            model.applyFilter(.type(.image))
            await model.waitForSearchForTesting()
            XCTAssertTrue(model.visibleItems.isEmpty)
            XCTAssertNil(model.selectedItemID, "A filtered-out anchor cannot remain actionable")
        }
    }

    func testFilterShortcutsIncludeAllAndBothAxesWhileRespectingExactModifiersAndExistingOwners() {
        var bindings = Dictionary(uniqueKeysWithValues: ClipboardHistoryFilterShortcuts.definitions.map { ($0.id, $0.binding) })
        func command(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> ClipboardHistoryPanelController.KeyboardCommand? {
            ClipboardHistoryPanelController.keyboardCommand(keyCode: key, modifiers: modifiers,
                isPanelEvent: true, isPanelKeyWindow: true, hasAttachedSheet: false, isEditingText: true,
                hasSelectedText: false, hasMarkedText: false, panelShortcutBindings: bindings)
        }
        XCTAssertEqual(command(18, [.command, .option]), .applyFilter(.type(.all)))
        XCTAssertEqual(command(20, [.command, .option]), .applyFilter(.type(.image)))
        XCTAssertEqual(command(18, [.command, .option, .shift]), .applyFilter(.contains(.any)))
        XCTAssertEqual(command(19, [.command, .option, .shift]), .applyFilter(.contains(.link)))
        XCTAssertEqual(command(20, [.command, .option, .shift]), .applyFilter(.contains(.email)))
        XCTAssertEqual(command(21, [.command, .option, .shift]), .applyFilter(.contains(.recognizedText)))
        XCTAssertEqual(command(29, [.command, .option]), .applyFilter(.clear))
        XCTAssertNil(command(20, [.command, .option, .control]))
        bindings[ClipboardHistoryPlugin.ShortcutID.panelPasteCombined] = ShortcutBinding(keyCode: 20, modifiers: [.command, .option])
        XCTAssertEqual(command(20, [.command, .option]), .pasteCombinedSelection)
        bindings[ClipboardHistoryPlugin.ShortcutID.panelCycleScope] = ShortcutBinding(keyCode: 18, modifiers: [.command, .option])
        XCTAssertEqual(command(18, [.command, .option]), .cycleScope(offset: 1))
        XCTAssertEqual(command(18, [.command, .option, .shift]), .cycleScope(offset: -1))
    }

    func testAllAndAnyResetOnlyTheirOwnAxis() {
        let filters = ClipboardHistoryFilterState(scope: .history, type: .image, contains: .recognizedText, savedOnly: true)
        XCTAssertEqual(filters.applying(.type(.all)), .init(scope: .history, contains: .recognizedText, savedOnly: true))
        XCTAssertEqual(filters.applying(.contains(.any)), .init(scope: .history, type: .image, savedOnly: true))
    }

    func testActionPaletteRoutesEffectiveTypeContentAndFixedScopeShortcutsWithoutFallback() throws {
        let imageID = try XCTUnwrap(ClipboardHistoryFilterShortcuts.id(for: .type(.image)))
        let linkID = try XCTUnwrap(ClipboardHistoryFilterShortcuts.id(for: .contains(.link)))
        let entries = [
            ClipboardHistoryExportMenuEntry(title: "Images", action: .filter(.type(.image)), shortcutDefinitionID: imageID),
            ClipboardHistoryExportMenuEntry(title: "Links", action: .filter(.contains(.link)), shortcutDefinitionID: linkID),
            ClipboardHistoryExportMenuEntry(title: "Snippets", action: .filter(.scope(.snippets)))
        ]
        // A custom content binding must replace its default in Command-K too.
        var bindings = [imageID: ShortcutBinding(keyCode: 20, modifiers: [.command, .option]),
                        linkID: ShortcutBinding(keyCode: 3, modifiers: [.command, .control])]
        func action(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags) -> ClipboardHistoryExportMenuEntry.Action? {
            ClipboardHistoryActionPaletteShortcuts.action(keyCode: key, modifiers: modifiers, entries: entries,
                bindings: bindings, isEditingText: true, hasSelectedText: false, hasMarkedText: false,
                isRecordingShortcut: false)
        }
        XCTAssertEqual(action(20, [.command, .option]), .filter(.type(.image)))
        XCTAssertEqual(action(3, [.command, .control]), .filter(.contains(.link)))
        XCTAssertNil(action(19, [.command, .option, .shift]))
        XCTAssertEqual(action(20, .control), .filter(.scope(.snippets)))
        XCTAssertNil(action(20, [.control, .shift]))
        bindings.removeValue(forKey: imageID)
        XCTAssertNil(action(20, [.command, .option]))
    }

    func testHostedShortcutSnapshotTreatsClearedBindingsAsAuthoritative() throws {
        let state = ClipboardHistoryPanelShortcuts()
        let id = try XCTUnwrap(ClipboardHistoryFilterShortcuts.id(for: .contains(.link)))
        let custom = ShortcutBinding(keyCode: 3, modifiers: [.command, .control])
        state.receiveHostBinding(id: "unrelated-shortcut", binding: custom)
        XCTAssertFalse(state.isHostManaged)
        state.receiveHostBinding(id: id, binding: nil)
        XCTAssertTrue(state.isHostManaged)
        XCTAssertNil(state.bindings[id])
        state.receiveHostBinding(id: id, binding: custom)
        XCTAssertEqual(state.bindings[id], custom)
        state.receiveHostBinding(id: id, binding: nil)
        XCTAssertNil(state.bindings[id])
        state.reset()
        XCTAssertFalse(state.isHostManaged)
        XCTAssertTrue(state.bindings.isEmpty)
    }

    private func item(text: String) -> ClipboardHistoryItem {
        .init(id: UUID(), text: text, capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }

    private func makeImage() -> ClipboardHistoryItem {
        .init(id: UUID(), payload: .init(pasteboardItems: [.init(representations: [
            .init(typeIdentifier: ClipboardRepresentationType.png, data: Data([1]))
        ])]), capturedAt: .now, sourceApplication: nil, isPinned: false, lastUsedAt: nil)
    }
}

@MainActor
private final class FilterSettingsStorage: PluginStorage {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}
