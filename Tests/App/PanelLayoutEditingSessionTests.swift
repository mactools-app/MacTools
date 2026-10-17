import AppKit
import Combine
import SwiftUI
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelLayoutEditingSessionTests: XCTestCase {

    func testDragPreviewOnlyCommitsOnDropAndUsesOriginalInsertionOffsets() throws {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c", "d"]
        XCTAssertNotNil(session.begin(id: "b", ids: ids))
        session.preview(offset: 4, ids: ids)
        XCTAssertEqual(session.previewIDs(currentIDs: ids), ["a", "c", "d", "b"])
        XCTAssertEqual(session.originalIDs, ids)
        XCTAssertEqual(session.finish(ids: ids), .init(id: "b", offset: 4))
        XCTAssertNil(session.sourceID)
        XCTAssertNil(session.token)
    }

    func testLeavingAndCancellingNeverProducesAMove() {
        let session = PanelLayoutEditingSession()
        let ids = ["a", "b", "c"]
        _ = session.begin(id: "c", ids: ids)
        session.preview(offset: 0, ids: ids)
        session.leave()
        XCTAssertEqual(session.previewIDs(currentIDs: ids), ids)
        XCTAssertNil(session.finish(ids: ids))
        _ = session.begin(id: "c", ids: ids)
        session.preview(offset: 0, ids: ids)
        session.cancel()
        XCTAssertNil(session.finish(ids: ids))
    }

    func testUnavailableSourceTargetAndExternalOrderChangesInvalidateDrag() {
        for changedIDs in [["b", "c"], ["a", "b"], ["c", "b", "a"], ["a", "b", "c", "d"]] {
            let session = PanelLayoutEditingSession()
            _ = session.begin(id: "a", ids: ["a", "b", "c"])
            session.preview(offset: 3, ids: ["a", "b", "c"])
            XCTAssertNil(session.finish(ids: changedIDs))
            XCTAssertNil(session.token)
        }
    }

    func testNoOpDropsAndInvalidStartsAreIgnored() {
        let session = PanelLayoutEditingSession()
        XCTAssertNil(session.begin(id: "missing", ids: ["a", "b"]))
        XCTAssertNotNil(session.begin(id: "a", ids: ["a"]), "A single item can move to another panel")
        for offset in [1, 2] {
            _ = session.begin(id: "b", ids: ["a", "b", "c"])
            session.preview(offset: offset, ids: ["a", "b", "c"])
            XCTAssertNil(session.finish(ids: ["a", "b", "c"]))
        }
    }

    func testUndoRestoresBothDirectionsAndBoundariesAndCannotOverwriteAnExternalMove() throws {
        for (id, offset) in [("a", 3), ("c", 0), ("b", 0), ("b", 3)] {
            let session = PanelLayoutEditingSession()
            let before = ["a", "b", "c"]
            let after = PanelLayoutDestination.moving(id, toOffset: offset, in: before)
            session.didSave(.init(id: id, offset: offset), beforeIDs: before, afterIDs: after)
            XCTAssertTrue(session.canUndo(ids: after))
            let undo = try XCTUnwrap(session.takeUndo(ids: after))
            XCTAssertEqual(PanelLayoutDestination.moving(undo.id, toOffset: undo.offset, in: after), before)
            XCTAssertNil(session.takeUndo(ids: after), "Undo is consumed exactly once")
            session.didSave(.init(id: id, offset: offset), beforeIDs: before, afterIDs: after)
            session.reconcile(ids: ["c", "b"])
            XCTAssertNil(session.takeUndo(ids: after), "A changed item list must invalidate history")
        }
    }

    func testOnlyOneEditingOverlayIsActiveAndDraggingClearsIt() {
        let hover = PanelLayoutHoverState()
        let first = hover.state(for: "first")
        let second = hover.state(for: "second")
        hover.focusChanged(id: "first", isFocused: true)
        XCTAssertTrue(first.isActive)
        hover.focusChanged(id: "second", isFocused: true)
        XCTAssertFalse(first.isActive)
        XCTAssertTrue(second.isActive)

        hover.setDragging(true)
        hover.focusChanged(id: "first", isFocused: true)
        XCTAssertNil(hover.activeItemID)
        XCTAssertFalse(first.isActive)
        XCTAssertFalse(second.isActive)

        hover.setDragging(false)
        XCTAssertTrue(first.isActive)
        XCTAssertFalse(second.isActive)
    }

    func testEditingControlsReceiveClicksWhileTheRestOfTheCardStaysDraggable() {
        let translations = [
            ["Remove", "Move to", "More"], ["移除", "移动到", "更多"],
            ["Entfernen", "Verschieben nach", "Mehr"], ["إزالة", "نقل إلى", "المزيد"]
        ]
        for titles in translations {
            let labels = PanelLayoutControlLabels(titles: titles)
            for size in [CGSize(width: 500, height: 200), CGSize(width: 304, height: 48),
                         CGSize(width: 160, height: 48), CGSize(width: 48, height: 144),
                         CGSize(width: 64, height: 32)] {
                for rightToLeft in [false, true] {
                    let parent = NSView(frame: CGRect(origin: .zero, size: size))
                    let source = PanelLayoutDragSourceView(frame: parent.bounds)
                    parent.addSubview(source)
                    source.controlLabels = labels
                    source.rightToLeft = rightToLeft
                    source.showsControls = true
                    source.updateTrackingAreas()
                    let metrics = PanelLayoutItemControlsLayout(size: size, labels: labels)
                    XCTAssertEqual(source.controlFrames, metrics.buttonFrames(in: source.bounds, rightToLeft: rightToLeft))
                    for frame in source.controlFrames {
                        XCTAssertTrue(source.bounds.contains(frame))
                        // Text, icon, and padding must all pass clicks through to SwiftUI.
                        for x in [frame.minX + 1, frame.midX, frame.maxX - 1] {
                            let point = source.convert(CGPoint(x: x, y: frame.midY), to: parent)
                            XCTAssertNil(source.hitTest(point), "Editing actions must not begin a drag")
                            source.showsControls = false
                            XCTAssertTrue(source.hitTest(point) === source)
                            source.showsControls = true
                        }
                    }
                    for (index, frame) in source.controlFrames.enumerated() {
                        for other in source.controlFrames.dropFirst(index + 1) {
                            XCTAssertFalse(frame.intersects(other))
                        }
                    }
                    let corner = source.convert(CGPoint(x: 1, y: 1), to: parent)
                    XCTAssertTrue(source.hitTest(corner) === source, "The remaining card area stays draggable")
                }
            }
        }
    }

    private func item(_ id: String, _ span: PluginPanelWidgetSpan) -> PluginPanelWidgetSnapshot {
        PluginPanelWidgetSnapshot(id: id, title: id, iconName: "circle", iconTint: .blue, description: "",
                            helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
    }
}
