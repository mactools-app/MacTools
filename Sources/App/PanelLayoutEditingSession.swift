import AppKit
import MacToolsPluginKit

/// Offsets use SwiftUI's move semantics: an insertion boundary in the original sequence.
enum PanelLayoutDestination {
    static let dropTailHeight: CGFloat = 8
    static func visibleContentHeight(itemHeight: CGFloat) -> CGFloat {
        itemHeight > 0 ? itemHeight + dropTailHeight : 0
    }

    static func editorDocumentHeight(itemHeight: CGFloat) -> CGFloat {
        visibleContentHeight(itemHeight: itemHeight)
    }

    static func editorContentHeight(itemHeight: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        let minimumHeight = max(0, MenuBarPanelLayout.minimumPanelHeight
            - MenuBarPanelLayout.editingPanelChromeHeight - MenuBarPanelLayout.editingActionBarHeight)
        return min(maximumHeight, max(minimumHeight, editorDocumentHeight(itemHeight: itemHeight)
            + MenuBarPanelLayout.contentVerticalPadding))
    }

    static func frame(_ placement: ComponentGridPlacement) -> CGRect {
        CGRect(
            x: ComponentPanelLayout.xOffset(for: placement), y: placement.yOffset,
            width: placement.size?.width ?? ComponentPanelLayout.itemWidth(for: placement.span),
            height: placement.size?.height ?? ComponentPanelLayout.itemHeight(for: placement.span)
        )
    }

    static func moving(_ id: String, toOffset offset: Int, in ids: [String]) -> [String] {
        guard let source = ids.firstIndex(of: id) else { return ids }
        let boundary = min(max(offset, 0), ids.count)
        var result = ids
        result.remove(at: source)
        result.insert(id, at: boundary > source ? boundary - 1 : boundary)
        return result
    }

    static func scrollDelta(pointerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, pointerY >= 0, pointerY <= viewportHeight else { return 0 }
        let edge = min(36, viewportHeight / 3)
        if pointerY < edge { return -12 * (1 - pointerY / edge) }
        if pointerY > viewportHeight - edge { return 12 * (1 - (viewportHeight - pointerY) / edge) }
        return 0
    }
}

@MainActor
final class PanelLayoutDragPreview: ObservableObject {
    @Published fileprivate(set) var target: PanelLayoutDropTarget?
}

@MainActor
final class PanelLayoutEditingSession: ObservableObject {
    struct Move: Equatable {
        let id: String
        let offset: Int
        var sourcePanelID: String? = nil
    }

    enum Feedback: Equatable {
        case guidance, saved, unchanged, cancelled, invalidated, undone

        var message: String {
            switch self {
            case .guidance: PanelLayoutCopy.hint
            case .saved: PanelLayoutCopy.saved
            case .unchanged: PanelLayoutCopy.unchanged
            case .cancelled: PanelLayoutCopy.cancelled
            case .invalidated: PanelLayoutCopy.invalidated
            case .undone: PanelLayoutCopy.undone
            }
        }
    }

    private struct UndoMove {
        let move: Move
        let expectedIDs: [String]
    }

    private struct TransferUndo {
        let change: MenuBarPanelLayoutChange
        let sourcePanelID: String
        let destinationPanelID: String
        let sourceIDs: [String]
        let destinationIDs: [String]
    }

    @Published private(set) var sourceID: String?
    // Pointer updates only invalidate the insertion marker, not the editor or its toolbar.
    let dragPreview = PanelLayoutDragPreview()
    var destination: Int? { dragPreview.target?.offset }
    @Published private(set) var feedback: Feedback = .guidance
    @Published private var undoMove: UndoMove?
    @Published private var transferUndo: TransferUndo?
    @Published private var layoutUndo: MenuBarPanelLayoutChange?
    private(set) var originalIDs: [String] = []
    private(set) var token: String?
    private(set) var sourcePanelID: String?
    private(set) var destinationPanelID: String?
    private var destinationIDs: [String] = []
    let nativeDragSource = PanelLayoutNativeDragSource()

    func begin(id: String, ids: [String]) -> String? {
        cancel()
        guard ids.contains(id) else { return nil }
        originalIDs = ids
        destinationIDs = ids
        sourceID = id
        token = UUID().uuidString
        feedback = .guidance
        AppLog.panelLayout.debug("Drag began with \(ids.count) rendered items")
        return token
    }

    func begin(entry: MenuBarPanelEntry, panelID: String, ids: [String]) -> String? {
        guard let token = begin(id: entry.id, ids: ids) else { return nil }
        sourcePanelID = panelID
        destinationPanelID = panelID
        return token
    }

    func enterPanel(_ panelID: String, ids: [String]) {
        guard token != nil, sourcePanelID != nil, destinationPanelID != panelID else { return }
        leave()
        destinationPanelID = panelID
        destinationIDs = ids
        undoMove = nil
        transferUndo = nil
    }

    func validateSource(in host: PluginHost) -> Bool {
        guard token != nil, let sourcePanelID,
              host.visibleMenuBarPanels.contains(where: { $0.id == sourcePanelID }),
              host.panelEntries(in: sourcePanelID).map(\.id) == originalIDs else {
            invalidate()
            return false
        }
        return true
    }

    func validate(in host: PluginHost, panelID: String) -> Bool {
        guard destinationPanelID == panelID, validateSource(in: host),
              host.visibleMenuBarPanels.contains(where: { $0.id == panelID }) else { return false }
        return validate(ids: host.panelEntries(in: panelID).map(\.id))
    }

    func validate(ids: [String]) -> Bool {
        guard sourceID != nil else { return false }
        guard ids == destinationIDs else {
            invalidate()
            return false
        }
        return true
    }

    func preview(offset: Int, ids: [String]) {
        preview(target: .init(offset: offset, markerFrame: nil), ids: ids)
    }

    func preview(target: PanelLayoutDropTarget, ids: [String]) {
        guard validate(ids: ids) else { return }
        let next = PanelLayoutDropTarget(offset: min(max(target.offset, 0), ids.count),
                                        markerFrame: target.markerFrame, isVacancy: target.isVacancy,
                                        previewFrame: target.previewFrame)
        guard dragPreview.target != next else { return }
        dragPreview.target = next
    }

    func previewIDs(currentIDs: [String]) -> [String] {
        guard currentIDs == destinationIDs, let sourceID, let destination else { return currentIDs }
        if sourcePanelID != destinationPanelID {
            var result = currentIDs
            result.insert(sourceID, at: min(max(destination, 0), result.count))
            return result
        }
        return PanelLayoutDestination.moving(sourceID, toOffset: destination, in: currentIDs)
    }

    func leave() {
        guard destination != nil else { return }
        dragPreview.target = nil
    }

    func finish(ids: [String]) -> Move? {
        defer { cancel() }
        guard validate(ids: ids), let sourceID, let destination else { return nil }
        guard previewIDs(currentIDs: ids) != ids else {
            feedback = .unchanged
            return nil
        }
        return Move(id: sourceID, offset: destination,
                    sourcePanelID: sourcePanelID == destinationPanelID ? nil : sourcePanelID)
    }

    func sourceEnded(token completedToken: String) {
        guard token == completedToken else { return }
        cancel()
        feedback = .cancelled
        AppLog.panelLayout.debug("Drag ended without a committed drop")
    }

    func invalidate() {
        guard token != nil else { return }
        cancel()
        feedback = .invalidated
        AppLog.panelLayout.debug("Drag invalidated by a changed layout")
    }

    func reconcile(ids: [String], panelID: String? = nil) {
        if let panelID {
            if let destinationPanelID, destinationPanelID != panelID { return }
            if let transferUndo, transferUndo.destinationPanelID != panelID { return }
        }
        if token != nil, ids != destinationIDs { invalidate() }
        if let undoMove, undoMove.expectedIDs != ids { self.undoMove = nil }
        if let transferUndo, transferUndo.destinationIDs != ids { self.transferUndo = nil }
    }

    func didSave(_ move: Move, beforeIDs: [String], afterIDs: [String]) {
        guard let before = beforeIDs.firstIndex(of: move.id),
              let after = afterIDs.firstIndex(of: move.id), beforeIDs != afterIDs else { return }
        layoutUndo = nil
        undoMove = UndoMove(move: Move(id: move.id, offset: before > after ? before + 1 : before),
                            expectedIDs: afterIDs)
        transferUndo = nil
        feedback = .saved
        AppLog.panelLayout.debug("Move saved from index \(before) to \(after)")
    }

    func canUndo(ids: [String]) -> Bool {
        token == nil && undoMove?.expectedIDs == ids
    }

    func takeUndo(ids: [String]) -> Move? {
        guard canUndo(ids: ids), let move = undoMove?.move else { return nil }
        undoMove = nil
        return move
    }

    func didUndo() { feedback = .undone }

    @discardableResult
    func commit(_ move: Move, in host: PluginHost, panelID: String) -> Bool {
        cancel()
        if let source = move.sourcePanelID, source != panelID {
            guard let entry = host.panelEntries(in: source).first(where: { $0.id == move.id }),
                  let change = host.transferPanelEntry(entry, from: source, to: panelID, at: move.offset) else {
                rejectMove()
                return false
            }
            undoMove = nil
            layoutUndo = nil
            transferUndo = TransferUndo(change: change, sourcePanelID: source, destinationPanelID: panelID,
                sourceIDs: host.panelEntries(in: source).map(\.id), destinationIDs: host.panelEntries(in: panelID).map(\.id))
            feedback = .saved
            return true
        }
        let entries = host.panelEntries(in: panelID)
        let before = entries.map(\.id)
        guard let entry = entries.first(where: { $0.id == move.id }) else { rejectMove(); return false }
        let result = PanelLayoutDestination.moving(move.id, toOffset: move.offset, in: before)
        guard result != before else { return true }
        host.movePanelEntry(entry, panelID: panelID, toOffset: move.offset)
        guard host.panelEntries(in: panelID).map(\.id) == result else { rejectMove(); return false }
        didSave(move, beforeIDs: before, afterIDs: result)
        return true
    }

    func canUndo(in host: PluginHost, panelID: String) -> Bool {
        guard token == nil else { return false }
        if let layoutUndo { return host.canUndoPanelLayoutChange(layoutUndo) }
        guard let transferUndo else { return canUndo(ids: host.panelEntries(in: panelID).map(\.id)) }
        return panelID == transferUndo.destinationPanelID && host.canUndoPanelLayoutChange(transferUndo.change)
            && host.panelEntries(in: panelID).map(\.id) == transferUndo.destinationIDs
            && host.panelEntries(in: transferUndo.sourcePanelID).map(\.id) == transferUndo.sourceIDs
    }

    func undo(in host: PluginHost, panelID: String) {
        guard canUndo(in: host, panelID: panelID) else { return }
        if let layoutUndo {
            self.layoutUndo = nil
            guard host.undoPanelLayoutChange(layoutUndo) else { rejectMove(); return }
        } else if let transferUndo {
            self.transferUndo = nil
            guard host.undoPanelLayoutChange(transferUndo.change) else { rejectMove(); return }
        } else {
            let before = host.panelEntries(in: panelID).map(\.id)
            guard let move = takeUndo(ids: before),
                  let entry = host.panelEntries(in: panelID).first(where: { $0.id == move.id }) else { return }
            host.movePanelEntry(entry, panelID: panelID, toOffset: move.offset)
            guard host.panelEntries(in: panelID).map(\.id) == PanelLayoutDestination.moving(move.id, toOffset: move.offset, in: before)
            else { rejectMove(); return }
        }
        didUndo()
    }

    func didSaveLayoutChange(_ change: MenuBarPanelLayoutChange) {
        cancel()
        undoMove = nil
        transferUndo = nil
        layoutUndo = change
        feedback = .saved
    }

    func rejectMove() {
        cancel()
        layoutUndo = nil
        undoMove = nil
        transferUndo = nil
        feedback = .invalidated
        AppLog.panelLayout.debug("Move rejected because the rendered order changed")
    }

    func cancel() {
        if destination != nil {
            dragPreview.target = nil
        }
        if sourceID != nil {
            sourceID = nil
        }
        originalIDs = []
        destinationIDs = []
        sourcePanelID = nil
        destinationPanelID = nil
        token = nil
    }

    func reset() {
        cancel()
        layoutUndo = nil
        if undoMove != nil {
            undoMove = nil
        }
        if transferUndo != nil { transferUndo = nil }
        if feedback != .guidance {
            feedback = .guidance
        }
    }
}

enum PanelLayoutCopy {
    static var edit: String { text("edit", "编辑面板") }
    static var done: String { text("done", "完成") }
    static var finishEditingHint: String { FeatureL10n.string("点击“完成”以结束编辑。") }
    static var earlier: String { text("earlier", "向前移动") }
    static var later: String { text("later", "向后移动") }
    static var beginning: String { text("beginning", "移到开头") }
    static var end: String { text("end", "移到末尾") }
    static var hint: String { text("hint", "拖移卡片排序，修改会自动保存。") }
    static var undo: String { text("undo", "撤销") }
    static var saved: String { text("saved", "布局已保存") }
    static var unchanged: String { text("unchanged", "位置未改变") }
    static var cancelled: String { text("cancelled", "已取消移动") }
    static var invalidated: String { text("invalidated", "布局已更新，请重新拖移。") }
    static var undone: String { text("undone", "已撤销移动") }
    static func position(_ title: String, index: Int, count: Int) -> String {
        AppL10n.settingsFormat("panel.layout.position", defaultValue: "%@，第 %lld 项，共 %lld 项", title, index + 1, count)
    }
    private static func text(_ key: String, _ fallback: String) -> String {
        AppL10n.settings("panel.layout.\(key)", defaultValue: fallback)
    }
}
