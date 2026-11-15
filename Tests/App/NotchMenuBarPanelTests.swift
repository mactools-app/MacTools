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

    func testWideCameraCutoutSurfaceHasSquareTopCornersAtEveryStage() {
        let anchor = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: CGSize(width: 349, height: 114.5))

        for fraction in [0.0, 0.3, 1.0] {
            let rect = metrics.surfaceRect(expandedFraction: fraction)
            let path = NotchSurfacePath.make(
                in: rect,
                radius: metrics.cornerRadius(for: rect, heightFraction: fraction),
                topRadius: metrics.topCornerRadius(for: rect, heightFraction: fraction)
            )

            XCTAssertEqual(rect.maxY, metrics.windowSize.height, "The surface stays pinned to the display edge.")
            XCTAssertTrue(path.contains(CGPoint(x: rect.minX + 0.5, y: rect.maxY - 0.5)))
            XCTAssertTrue(path.contains(CGPoint(x: rect.maxX - 0.5, y: rect.maxY - 0.5)))
            XCTAssertFalse(path.contains(CGPoint(x: rect.minX + 0.5, y: rect.minY + 0.5)),
                           "Bottom corners stay rounded.")
        }
    }

    func testHeaderRowIsCenteredOnTheCameraHousing() {
        let anchors = [
            CGRect(x: 838.5, y: 1093, width: 59, height: 40),  // compact island
            CGRect(x: 663.5, y: 950, width: 185, height: 32),  // wide camera cutout
        ]
        for anchor in anchors {
            let metrics = NotchMorphMetrics(anchor: anchor, contentSize: CGSize(width: 349, height: 114))
            let headerCenter = metrics.contentTopInset
                + MenuBarPanelLayout.panelTopPadding + MenuBarPanelLayout.headerHeight / 2
            let housingCenter = metrics.housingOffset + metrics.housingSize.height / 2

            XCTAssertEqual(headerCenter, housingCenter, accuracy: 0.5, "\(anchor.size)")
            XCTAssertGreaterThanOrEqual(headerCenter - MenuBarPanelLayout.headerHeight / 2, 0,
                                        "The header stays inside the surface.")
        }
    }

    func testCompactIslandKeepsAnInsetFromDisplayTop() {
        let anchor = CGRect(x: 838.5, y: 1093, width: 59, height: 40)
        let metrics = NotchMorphMetrics(anchor: anchor, contentSize: CGSize(width: 316, height: 114))
        let expandedSurface = metrics.screenRect(fromSurfaceRect: metrics.surfaceRect(expandedFraction: 1))

        XCTAssertLessThan(expandedSurface.maxY, anchor.maxY)
    }
}
