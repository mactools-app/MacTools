import XCTest
@testable import MacTools

@MainActor
final class NotchMenuBarPanelTests: XCTestCase {
    func testWideNotchNeedsRoomForActionsEvenWithOneTab() {
        XCTAssertFalse(NotchMenuBarPanel.headerFitsBesideIsland(tabCount: 1, panelWidth: 316, notchWidth: 180))
        XCTAssertTrue(NotchMenuBarPanel.headerFitsBesideIsland(tabCount: 1, panelWidth: 350, notchWidth: 180))
    }
}
