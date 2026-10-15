import AppKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class PinViewTests: XCTestCase {
    func testControlsForASmallImageStayOnScreenWithoutCoveringIt() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 104, height: 44)
        for image in [NSRect(x: 600, y: 400, width: 60, height: 30),     // free space below
                      NSRect(x: 600, y: 0, width: 60, height: 30),       // at the bottom edge
                      NSRect(x: 0, y: 870, width: 40, height: 30)] {     // in the top-left corner
            let frame = PinView.controlsFrame(adjacentTo: image, size: size, within: screen)
            XCTAssertTrue(screen.contains(frame), "\(image)")
            XCTAssertTrue(frame.intersection(image).isEmpty, "\(image)")
        }
    }
}
