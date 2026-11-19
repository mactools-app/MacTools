import AppKit
import XCTest
@testable import MacTools

@MainActor
final class MacToolsAppDelegateTests: XCTestCase {
    func testXCTestLaunchNeverStartsLivePluginRuntime() {
        let delegate = MacToolsAppDelegate(acceptedURLSchemes: ["mactools"])
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        XCTAssertFalse(delegate.hasStartedRuntimeForTesting)
    }

    func testBackgroundExecutionSuppressesSettingsInEitherEventOrder() {
        var showSettingsCount = 0
        let scheduler = SettingsRecoveryScheduler(delay: .seconds(60)) {
            showSettingsCount += 1
        }

        scheduler.request()
        XCTAssertTrue(scheduler.hasPendingRequestForTesting)

        scheduler.noteBackgroundExecution()
        XCTAssertFalse(scheduler.hasPendingRequestForTesting)
        scheduler.runPendingRequestForTesting()
        XCTAssertEqual(showSettingsCount, 0)

        scheduler.cancel()
        scheduler.request()
        scheduler.runPendingRequestForTesting()
        XCTAssertEqual(showSettingsCount, 1)

        scheduler.noteBackgroundExecution()
        XCTAssertTrue(scheduler.isSuppressionActiveForTesting)
        scheduler.request()
        XCTAssertFalse(scheduler.hasPendingRequestForTesting)
        XCTAssertTrue(scheduler.isSuppressionActiveForTesting)
        XCTAssertEqual(showSettingsCount, 1)

        scheduler.request()
        XCTAssertFalse(scheduler.hasPendingRequestForTesting)
        XCTAssertEqual(showSettingsCount, 1)

        scheduler.cancel()
        scheduler.request()
        scheduler.runPendingRequestForTesting()
        XCTAssertEqual(showSettingsCount, 2)
    }

    func testAppIntentsServiceCannotQuitAppOrOpenSettings() {
        var senderPath: String? = AppleEventSender.appIntentsServicePath
        let delegate = MacToolsAppDelegate(
            acceptedURLSchemes: ["mactools"],
            appleEventSenderPath: { senderPath }
        )
        var showSettingsCount = 0
        delegate.setShowSettingsForRecoveryForTesting { showSettingsCount += 1 }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        XCTAssertEqual(showSettingsCount, 0)

        for path in ["/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", nil] {
            senderPath = path
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
            _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        }
        XCTAssertEqual(showSettingsCount, 2)
    }

    func testIncomingDeepLinksAreQueuedBeforeRuntimeCreation() {
        let delegate = MacToolsAppDelegate(acceptedURLSchemes: ["mactools"])
        let urls = [
            URL(string: "mactools://app/search")!,
            URL(string: "mactools://app/settings")!,
        ]

        delegate.application(NSApplication.shared, open: urls)

        XCTAssertEqual(delegate.pendingURLsForTesting(), urls)
    }

    func testPrimaryAcceptsForwardedDeepLinksBeforeRuntimeCreation() {
        let delegate = MacToolsAppDelegate(acceptedURLSchemes: ["mactools"])
        let urls = [URL(string: "mactools://app/search")!]

        XCTAssertEqual(delegate.handleInstanceURLsCommandForTesting(urls), .accepted)
        XCTAssertEqual(delegate.pendingURLsForTesting(), urls)
    }

    func testLaunchQueueRejectsInvalidAndOverflowingDeepLinks() {
        let delegate = MacToolsAppDelegate(acceptedURLSchemes: ["mactools"])
        delegate.application(
            NSApplication.shared,
            open: [URL(string: "https://example.com")!]
        )
        XCTAssertTrue(delegate.pendingURLsForTesting().isEmpty)

        let urls = (0..<33).map { index in
            URL(string: "mactools://app/search?index=\(index)")!
        }
        delegate.application(NSApplication.shared, open: urls)
        XCTAssertTrue(delegate.pendingURLsForTesting().isEmpty)

        let oversizedURL = URL(
            string: "mactools://right-click/open-terminal?directory=/tmp/\(String(repeating: "x", count: AppInstanceCommand.maximumPayloadSize))"
        )!
        delegate.application(NSApplication.shared, open: [oversizedURL])
        XCTAssertTrue(delegate.pendingURLsForTesting().isEmpty)
    }
}
