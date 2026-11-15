import CoreGraphics
import XCTest
@testable import MacTools

@MainActor
final class NotchMenuBarPanelTests: XCTestCase {
    func testWideNotchNeedsRoomForActionsEvenWithOneTab() {
        XCTAssertFalse(NotchMenuBarPanel.headerFitsBesideIsland(tabCount: 1, panelWidth: 316, notchWidth: 180))
        XCTAssertTrue(NotchMenuBarPanel.headerFitsBesideIsland(tabCount: 1, panelWidth: 350, notchWidth: 180))
    }

    func testHeaderWidthFitsGroupsBesideOlderMacBookProNotch() {
        let width = NotchMenuBarPanel.minimumWidthForHeaderBesideIsland(tabCount: 2, notchWidth: 185)

        XCTAssertGreaterThan(width, MenuBarPanelLayout.baseWidth)
        XCTAssertTrue(NotchMenuBarPanel.headerFitsBesideIsland(tabCount: 2, panelWidth: width, notchWidth: 185))
    }

    func testWideCameraCutoutPanelReachesDisplayTop() {
        let anchor = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: CGSize(width: 349, height: 114.5))
        let expandedSurface = metrics.screenRect(fromSurfaceRect: metrics.surfaceRect(expandedFraction: 1))

        XCTAssertEqual(expandedSurface.maxY, anchor.maxY)
    }

    func testCompactIslandKeepsAnInsetFromDisplayTop() {
        let anchor = CGRect(x: 838.5, y: 1093, width: 59, height: 40)
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: CGSize(width: 316, height: 114))
        let expandedSurface = metrics.screenRect(fromSurfaceRect: metrics.surfaceRect(expandedFraction: 1))

        XCTAssertLessThan(expandedSurface.maxY, anchor.maxY)
    }
}
