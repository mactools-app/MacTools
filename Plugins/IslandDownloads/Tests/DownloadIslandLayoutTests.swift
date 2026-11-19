import XCTest
@testable import IslandDownloadsPlugin

final class DownloadIslandLayoutTests: XCTestCase {
    private let island = CGRect(x: 836, y: 1086, width: 60, height: 34)

    func testCompactUsesOnlyFreeMenuBarSpace() {
        let layout = DownloadIslandLayout.resolve(island: island, systemActivity: false, nameWidth: nil,
                                                  leftLimit: 400, rightLimit: 1200)
        guard case let .compact(capsule, _, _) = layout else { return XCTFail("expected compact, got \(layout)") }
        XCTAssertGreaterThanOrEqual(capsule.minX, 400 + DownloadIslandMetrics.clearance)
        XCTAssertLessThanOrEqual(capsule.maxX, 1200 - DownloadIslandMetrics.clearance)

        // A menu reaching the island leaves only the trailing side; nothing fits either side: hidden.
        XCTAssertEqual(DownloadIslandLayout.resolve(island: island, systemActivity: false, nameWidth: nil,
                                                    leftLimit: 830, rightLimit: 1200),
                       .trailing(capsule: CGRect(x: 836, y: 1086, width: 92, height: 34), island: island))
        XCTAssertEqual(DownloadIslandLayout.resolve(island: island, systemActivity: false, nameWidth: nil,
                                                    leftLimit: 830, rightLimit: 900), .hidden)
    }

    func testNameWidensOnlyWhenItFitsAndSystemActivityGetsADetachedBubble() {
        let narrow = DownloadIslandLayout.resolve(island: island, systemActivity: false, nameWidth: 300,
                                                  leftLimit: 780, rightLimit: 1200)
        XCTAssertEqual(narrow.leadingWidth, DownloadIslandMetrics.glyphWing)
        let named = DownloadIslandLayout.resolve(island: island, systemActivity: false, nameWidth: 60,
                                                 leftLimit: 400, rightLimit: 1200)
        XCTAssertGreaterThan(named.leadingWidth, DownloadIslandMetrics.glyphWing)

        let bubble = DownloadIslandLayout.resolve(island: island, systemActivity: true, nameWidth: 60,
                                                  leftLimit: 400, rightLimit: 1200)
        XCTAssertTrue(bubble.isDetached)
        XCTAssertEqual(bubble.capsule?.minX, island.maxX + DownloadIslandMetrics.detachedGap)
    }
}
