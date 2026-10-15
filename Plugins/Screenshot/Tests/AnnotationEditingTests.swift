import AppKit
import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class ScreenshotAnnotationEditingTests: XCTestCase {
    func testRectangleCanBeReselectedMovedResizedAndUndoneWithoutExportingHandles() async throws {
        let editor = try Editor()
        defer { editor.close() }
        let original = NSRect(x: 200, y: 200, width: 120, height: 80)
        try editor.draw("rect", original)
        try editor.drag(from: NSPoint(x: 260, y: 240), to: NSPoint(x: 300, y: 260), attemptUndoDuringDrag: true)
        let moved = original.offsetBy(dx: 40, dy: 20)
        try await assertExport(editor, items: [item(.rect(moved))])

        try editor.drag(from: NSPoint(x: moved.maxX, y: moved.maxY), to: NSPoint(x: 400, y: 340))
        try await assertExport(editor, items: [item(.rect(NSRect(x: 240, y: 220, width: 160, height: 120)))])
        editor.view.undo(nil)
        try await assertExport(editor, items: [item(.rect(moved))])
        editor.view.undo(nil)
        try await assertExport(editor, items: [item(.rect(original))])
        editor.view.undo(nil)
        try await assertExport(editor, items: [])
    }

    func testDrawingCreatesNestedItemsAndSelectionTargetsTheTopmostEditableItem() async throws {
        let editor = try Editor()
        defer { editor.close() }
        let outer = NSRect(x: 180, y: 180, width: 220, height: 180)
        let light = NSRect(x: 230, y: 210, width: 100, height: 80)
        try editor.draw("rect", outer)
        try editor.draw("spotlight", light)
        try editor.drag(from: NSPoint(x: 280, y: 250), to: NSPoint(x: 320, y: 270))
        let movedLight = light.offsetBy(dx: 40, dy: 20)
        let nested = NSRect(x: 290, y: 250, width: 30, height: 30)
        try editor.draw("rect", nested)

        try await assertExport(editor, items: [item(.rect(outer)), item(.spotlight(movedLight)), item(.rect(nested))])
        editor.view.undo(nil)
        editor.view.undo(nil)
        try await assertExport(editor, items: [item(.rect(outer)), item(.spotlight(light))])
    }

    func testSpotlightClampsToCropAndArrowMovementAndNoOpDragsHaveCorrectUndo() async throws {
        let editor = try Editor()
        defer { editor.close() }
        let original = NSRect(x: 200, y: 200, width: 120, height: 80)
        try editor.draw("spotlight", original)
        try editor.drag(from: NSPoint(x: 260, y: 240), to: NSPoint(x: -100, y: -100))
        let corner = NSRect(x: 100, y: 100, width: 120, height: 80)
        try await assertExport(editor, items: [item(.spotlight(corner))])
        try editor.drag(from: NSPoint(x: 160, y: 140), to: NSPoint(x: -100, y: -100))
        editor.view.undo(nil)
        try await assertExport(editor, items: [item(.spotlight(original))])

        try editor.key(124, flags: .shift)
        try await assertExport(editor, items: [item(.spotlight(original.offsetBy(dx: 10, dy: 0)))])
        editor.view.undo(nil)
        try editor.drag(from: NSPoint(x: original.maxX, y: original.maxY), to: NSPoint(x: 1200, y: 900))
        let expanded = NSRect(x: 200, y: 200, width: editor.crop.maxX - 200, height: editor.crop.maxY - 200)
        try await assertExport(editor, items: [item(.spotlight(expanded))])
    }

    func testRecroppingAndReusingOverlayDiscardAnnotationHistory() async throws {
        let editor = try Editor()
        defer { editor.close() }
        try editor.draw("rect", NSRect(x: 200, y: 200, width: 120, height: 80))
        try editor.drag(from: NSPoint(x: 50, y: 50), to: NSPoint(x: 700, y: 500))
        editor.view.undo(nil)
        try await assertExport(editor, items: [], crop: NSRect(x: 50, y: 50, width: 650, height: 450))

        editor.view.prepare(frozen: editor.image, windows: [], quick: false)
        try editor.drag(from: editor.crop.origin, to: NSPoint(x: editor.crop.maxX, y: editor.crop.maxY))
        editor.view.undo(nil)
        try await assertExport(editor, items: [])
    }

    func testFillCanBeSetBeforeDrawingAndToggledOnTheSelectedShapeWithUndo() async throws {
        let editor = try Editor()
        defer { editor.close() }
        let oval = NSRect(x: 200, y: 200, width: 120, height: 80)
        try editor.pick("ellipse")
        try editor.click("screenshot.style.fill")
        try editor.drag(from: oval.origin, to: NSPoint(x: oval.maxX, y: oval.maxY))
        try await assertExport(editor, items: [item(.ellipse(oval), filled: true)])

        // The new ellipse stays selected, so the same control turns it back into an outline.
        try editor.click("screenshot.style.fill")
        try await assertExport(editor, items: [item(.ellipse(oval))])
        editor.view.undo(nil)
        try await assertExport(editor, items: [item(.ellipse(oval), filled: true)])

        try editor.drag(from: NSPoint(x: oval.midX, y: oval.midY), to: NSPoint(x: oval.midX + 30, y: oval.midY))
        try await assertExport(editor, items: [item(.ellipse(oval.offsetBy(dx: 30, dy: 0)), filled: true)])
    }

    func testTextRecognitionFromTheModeBarNeverRevealsTheAnnotationToolbar() throws {
        let editor = try Editor()
        defer { editor.close() }
        var cancelled = false
        editor.view.onCancel = { cancelled = true }
        let modeBar = try XCTUnwrap(editor.descendants().first { $0.identifier?.rawValue == "screenshot.modeBar" })
        // Mode-bar order: screenshot, scrolling, recording, text recognition.
        try XCTUnwrap(editor.descendants(of: modeBar).compactMap { $0 as? NSButton }.first { $0.tag == 3 }).performClick(nil)
        let annotationTool = try XCTUnwrap(editor.descendants().compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "screenshot.tool.rect" })
        XCTAssertTrue(annotationTool.isHiddenOrHasHiddenAncestor)

        let close = try XCTUnwrap(editor.descendants().compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("closeOcr") })
        try editor.drag(from: NSPoint(x: 500, y: 400), to: NSPoint(x: 520, y: 410))
        XCTAssertTrue(annotationTool.isHiddenOrHasHiddenAncestor, "Moving a text-recognition selection must not show annotation tools")
        close.performClick(nil)
        XCTAssertTrue(cancelled, "Closing recognition chosen from the mode bar ends the capture")
        XCTAssertTrue(annotationTool.isHiddenOrHasHiddenAncestor)
    }

    private func item(_ shape: Shape, filled: Bool = false) -> Item {
        Item(shape: shape, stroke: Stroke(color: .systemRed, width: 2, filled: filled))
    }

    private func assertExport(_ editor: Editor, items: [Item], crop: NSRect? = nil,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let finished = expectation(description: "Screenshot encoded")
        var result: Data?
        editor.view.onComplete = { png, _ in result = png; finished.fulfill() }
        editor.view.copy(nil)
        await fulfillment(of: [finished], timeout: 3)
        let image = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(result))?.cgImage)
        let renderer = AnnotationRenderer(image: editor.image, scale: 1, size: editor.view.bounds.size)
        let expected = try XCTUnwrap(renderer.render(selection: crop ?? editor.crop, items: items,
                                                     radius: 0, shadowSize: 0, shadowColor: .black))
        XCTAssertEqual(image.width, expected.image.width, file: file, line: line)
        XCTAssertEqual(image.height, expected.image.height, file: file, line: line)
        let actualPixels = try pixels(image)
        let expectedPixels = try pixels(expected.image)
        XCTAssertTrue(actualPixels == expectedPixels, "Export changed geometry, stroke, crop, or included editing handles",
                      file: file, line: line)
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}

@MainActor
private final class Editor {
    let view: OverlayView
    let window: NSWindow
    let image: CGImage
    let crop = NSRect(x: 100, y: 100, width: 800, height: 560)

    init() throws {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 760)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 760, bitsPerComponent: 8,
                                             bytesPerRow: 4000, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(bounds)
        image = try XCTUnwrap(context.makeImage())
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        view = OverlayView(frame: bounds, environment: environment)
        window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.prepare(frozen: image, windows: [], quick: false)
        try drag(from: crop.origin, to: NSPoint(x: crop.maxX, y: crop.maxY))
    }

    func close() { view.stop(); window.close() }

    func draw(_ tool: String, _ rect: NSRect) throws {
        try pick(tool)
        try drag(from: rect.origin, to: NSPoint(x: rect.maxX, y: rect.maxY))
    }

    func pick(_ tool: String) throws {
        try click("screenshot.tool.\(tool)")
    }

    func descendants(of parent: NSView? = nil) -> [NSView] {
        (parent ?? view).subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func click(_ identifier: String) throws {
        let button = try XCTUnwrap(descendants().compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier })
        button.performClick(nil)
    }

    func drag(from start: NSPoint, to end: NSPoint, attemptUndoDuringDrag: Bool = false) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, at: start))
        if attemptUndoDuringDrag {
            view.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: (start.x + end.x) / 2,
                                                                           y: (start.y + end.y) / 2)))
            view.undo(nil)
            try key(124)
        }
        // Final mouse-up coordinates must apply even when AppKit coalesces drag samples.
        view.mouseUp(with: try mouse(.leftMouseUp, at: end))
    }

    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws {
        view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)))
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 0))
    }
}
