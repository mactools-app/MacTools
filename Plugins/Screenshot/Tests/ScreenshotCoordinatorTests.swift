import MacToolsPluginKit
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class ScreenshotCoordinatorTests: XCTestCase {
    /// A recording can finish while a later screenshot is in progress; only cancelling the plugin
    /// may suppress its completion messages.
    func testRecordingMessagesFollowTheSessionNotLaterScreenshots() {
        let environment = ScreenshotEnvironment(context: PluginRuntimeContext(pluginID: "screenshot", storage: ScreenshotTestStorage()))
        let coordinator = ScreenshotCoordinator(environment: environment)
        var errors: [String] = []
        coordinator.onError = { errors.append($0) }
        let session = coordinator.sessionToken

        coordinator.recordingFinished(.failure(TestError.failed), session: session)
        XCTAssertEqual(errors.count, 1)

        coordinator.cancel()
        coordinator.recordingFinished(.failure(TestError.failed), session: session)
        XCTAssertEqual(errors.count, 1, "A disabled plugin must not report its old recording")
    }

    private enum TestError: Error { case failed }
}
