import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class SettingsNavigationCoordinatorTests: XCTestCase {

    func testDirectPluginSettingsNavigationEndsPreviousVisibilityBeforeStartingNext() {
        XCTAssertEqual(
            PluginSettingsPageVisibilityTransition.changes(
                from: "trackpad-gestures",
                to: "fan-control"
            ),
            [
                .init(pluginID: "trackpad-gestures", isVisible: false),
                .init(pluginID: "fan-control", isVisible: true),
            ]
        )
        XCTAssertTrue(PluginSettingsPageVisibilityTransition.changes(
            from: "trackpad-gestures",
            to: "trackpad-gestures"
        ).isEmpty)
    }

    func testRecordsCompletePluginDestinationsAndRestoresExactPaneDuringTraversal() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        coordinator.navigate(to: .plugins(.actionsAndShortcuts))
        coordinator.navigate(to: .plugins(.automation))
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .about)

        XCTAssertEqual(
            coordinator.history,
            [
                .general,
                .plugins(.actionsAndShortcuts),
                .plugins(.automation),
                .plugins(.marketplace),
                .plugins(.configuration("fan-control")),
                .about
            ]
        )

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.configuration("fan-control")))
        XCTAssertEqual(coordinator.history.count, 6)
        XCTAssertEqual(coordinator.historyIndex, 4)
    }

    func testNormalNavigationAfterBackInvalidatesForwardHistory() {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigate(to: .about)
        coordinator.navigate(to: .plugins(.marketplace))
        coordinator.goBack()
        coordinator.navigate(to: .plugins(.actionsAndShortcuts))

        XCTAssertEqual(
            coordinator.history,
            [.general, .about, .plugins(.actionsAndShortcuts)]
        )
        XCTAssertEqual(coordinator.destination, .plugins(.actionsAndShortcuts))
        XCTAssertFalse(coordinator.canGoForward)
    }

    func testTraversalSkipsPluginConfigurationsThatAreNoLongerAvailable() {
        var availableConfigurationIDs: Set<String> = ["fan-control"]
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { availableConfigurationIDs.contains($0) }
        )

        coordinator.navigate(to: .plugins(.configuration("fan-control")))
        coordinator.navigate(to: .plugins(.marketplace))
        availableConfigurationIDs.remove("fan-control")

        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertTrue(coordinator.canGoForward)

        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .plugins(.marketplace))
    }

    func testSearchNavigationKeepsPaletteOpenForUnavailablePlugin() {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { _ in false }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("removed-plugin")),
            target: .plugin(
                PluginSettingsSearchTarget(
                    pluginID: "removed-plugin",
                    entryID: "setting"
                )
            )
        )

        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertEqual(coordinator.history, [.general])
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationRejectsMismatchedTargetAndDestination() {
        let coordinator = SettingsNavigationCoordinator()
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertFalse(
            coordinator.navigateFromSearch(
                to: .plugins(.configuration("other-plugin")),
                target: .plugin(
                    PluginSettingsSearchTarget(pluginID: "display", entryID: "control.brightness")
                )
            )
        )
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testSearchNavigationDismissesPaletteAndPublishesExactRevealTarget() throws {
        let coordinator = SettingsNavigationCoordinator(
            isPluginConfigurationAvailable: { $0 == "keep-awake" }
        )
        let target = PluginSettingsSearchTarget(
            pluginID: "keep-awake",
            entryID: "keep-display-on"
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        coordinator.navigateFromSearch(
            to: .plugins(.configuration("keep-awake")),
            target: .plugin(target)
        )

        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(
            coordinator.destination,
            .plugins(.configuration("keep-awake"))
        )
        let request = try XCTUnwrap(coordinator.searchRevealRequest)
        XCTAssertEqual(request.target, .plugin(target))

        coordinator.clearSearchRevealRequest(request)
        XCTAssertNil(coordinator.searchRevealRequest)
    }

    func testMarketplaceDetailSearchPreservesHighlightAndRejectsStaleDestination() {
        let target = MarketplacePluginDetailTarget(
            pluginID: "catalog-tool", providerID: "catalog-provider", actionID: "cleanup"
        )
        let destination = SettingsNavigationDestination.marketplaceDetail(target)
        var isAvailable = true
        let coordinator = SettingsNavigationCoordinator(
            isMarketplaceDetailAvailable: { isAvailable && $0 == target }
        )
        coordinator.presentUnifiedSearch(origin: .keyboard)

        XCTAssertTrue(coordinator.navigateFromSearch(to: destination, target: nil))
        XCTAssertFalse(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, destination)
        XCTAssertEqual(coordinator.destination.sidebarDestination, .plugins(.marketplace))
        XCTAssertNil(coordinator.searchRevealRequest)
        coordinator.goBack()
        XCTAssertEqual(coordinator.destination, .general)
        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, destination)

        coordinator.goBack()
        isAvailable = false
        coordinator.goForward()
        XCTAssertEqual(coordinator.destination, .general)
        coordinator.presentUnifiedSearch(origin: .keyboard)
        XCTAssertFalse(coordinator.navigateFromSearch(to: destination, target: nil))
        XCTAssertTrue(coordinator.isUnifiedSearchPresented)
        XCTAssertEqual(coordinator.destination, .general)
    }

}
