import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class AppURLRouterTests: XCTestCase {

    func testParserAcceptsDocumentedReleaseDebugAndNightlyRoutes() throws {
        let routes: [(String, AppDeepLink)] = [
            ("settings", .settings(.root)),
            ("settings/general", .settings(.general)),
            ("settings/permissions", .settings(.permissions)),
            ("settings/about", .settings(.about)),
            ("settings/features/actions-and-shortcuts", .settings(.actionsAndShortcuts)),
            ("settings/features/automation", .settings(.automation)),
            ("settings/plugins/marketplace", .settings(.pluginMarketplace)),
            ("settings/starter-packs", .settings(.starterPacks(nil))),
            ("settings/starter-packs/everyday", .settings(.starterPacks(.everyday))),
            ("settings/starter-packs/windows", .settings(.starterPacks(.windows))),
            ("settings/starter-packs/writing", .settings(.starterPacks(.writing))),
            ("settings/starter-packs/meetings", .settings(.starterPacks(.meetings))),
            ("settings/starter-packs/displays", .settings(.starterPacks(.displays))),
            ("settings/starter-packs/developer", .settings(.starterPacks(.developer))),
            ("settings/starter-packs/maintenance", .settings(.starterPacks(.maintenance))),
            ("settings/plugins/fan-control", .settings(.pluginConfiguration("fan-control"))),
            ("panels/dashboard", .panel(.dashboard)),
            ("panels/feature", .panel(.feature)),
            ("search", .search)
        ]

        for scheme in ["mactools", "mactools-dev", "mactools-nightly"] {
            for (path, expected) in routes {
                let parsed = AppDeepLinkParser.parse(
                    try XCTUnwrap(URL(string: "\(scheme)://app/\(path)")),
                    acceptedSchemes: [scheme]
                )
                XCTAssertEqual(parsed, .success(expected), "Failed route: \(scheme)://app/\(path)")
            }
        }
    }

    func testPackLinksOnlyPresentKnownPacksWithoutApplyingSetup() throws {
        for pack in StarterPack.allCases {
            let link = AppDeepLink.settings(.starterPacks(pack))
            XCTAssertEqual(link.presentationRequest, .settings(.starterPacks(pack)))
        }
        for suffix in ["unknown", "everyday/install", "everyday?install=true", "windows?", "everyday%2Fwindows"] {
            let url = try XCTUnwrap(URL(string: "mactools://app/settings/starter-packs/\(suffix)"))
            if case .success = AppDeepLinkParser.parseRoute(url, acceptedSchemes: ["mactools"]) {
                XCTFail("Accepted unsupported pack link: \(suffix)")
            }
        }
    }

    func testParserAcceptsDocumentedActionAndPresetRoutesInAllSchemes() throws {
        let presetID = UUID(uuidString: "7B420000-0000-0000-0000-000000000001")!

        for scheme in ["mactools", "mactools-dev", "mactools-nightly"] {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/actions/microphone-mute/toggle")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(
                    .run(
                        .direct(
                            ActionKey(providerID: "microphone-mute", actionID: "toggle")
                        )
                    )
                )
            )
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(
                        URL(string: "\(scheme)://app/presets/\(presetID.uuidString)")
                    ),
                    acceptedSchemes: [scheme]
                ),
                .success(.run(.preset(presetID)))
            )
        }
    }

    func testNavigationOnlyParserDoesNotExecuteActionRoutes() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/actions/display-sleep/sleep")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.unsupportedRoute)
        )
    }

    func testActionParserRejectsParametersMalformedIDsAndEncodedSeparators() throws {
        let cases: [(String, AppURLRoutingError)] = [
            (
                "mactools://app/actions/display-sleep/sleep?confirm=false",
                .unexpectedActionParameters
            ),
            ("mactools://app/actions/display-sleep/sleep?", .unexpectedActionParameters),
            (
                "mactools://app/actions/display-sleep/sleep?x=1&x=2",
                .duplicatedParameter("x")
            ),
            ("mactools://app/actions/a/b", .malformedActionID),
            ("mactools://app/actions/display-sleep/bad%20id", .malformedActionID),
            ("mactools://app/actions/display-sleep/sleep%2Fnow", .unsupportedRoute),
            ("mactools://app/actions/display-sleep/%2E%2E", .unsupportedRoute),
            ("mactools://app/presets/not-a-uuid", .invalidPresetID),
            (
                "mactools://app/presets/7B420000-0000-0000-0000-000000000001?x=1",
                .unexpectedActionParameters
            ),
        ]

        for (urlString, expected) in cases {
            XCTAssertEqual(
                AppDeepLinkParser.parseRoute(
                    try XCTUnwrap(URL(string: urlString)),
                    acceptedSchemes: ["mactools"]
                ),
                .failure(expected),
                "Unexpected result for \(urlString)"
            )
        }
    }

    func testParserRejectsDuplicateParameters() throws {
        let url = try XCTUnwrap(
            URL(string: "mactools://app/search?source=website&source=docs")
        )

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.duplicatedParameter("source"))
        )
    }

    func testParserRejectsUnknownAndMalformedDestinations() throws {
        let cases: [(String, AppURLRoutingError)] = [
            ("not-a-url", .malformedURL),
            ("other://app/settings", .unsupportedScheme),
            ("mactools://other/settings", .unsupportedHost),
            ("mactools://app/settings/plugins/a", .malformedPluginID),
            ("mactools://app/settings/plugins/bad%20id", .malformedPluginID),
            ("mactools://app/settings/plugins/fan-control%0A", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control%0D", .unsupportedRoute),
            ("mactools://app/settings/unknown", .unsupportedRoute),
            ("mactools://app//settings", .unsupportedRoute),
            ("mactools://app/settings//", .unsupportedRoute),
            ("mactools://app/panels/dashboard//", .unsupportedRoute),
            ("mactools://app/search//", .unsupportedRoute),
            ("mactools://app/settings/plugins/fan-control//", .unsupportedRoute),
            ("mactools://app/panels%2Fdashboard", .unsupportedRoute),
            ("mactools://app/panels%2fdashboard", .unsupportedRoute),
            ("mactools://app/settings%2Fplugins%2Ffan-control", .unsupportedRoute),
            ("mactools://app/panels%5Cdashboard", .unsupportedRoute),
            ("mactools://app/settings/%2E%2E/about", .unsupportedRoute),
            ("mactools://app/panels/%00dashboard", .unsupportedRoute),
            ("mactools://app/plugins/fan-control/commands/start", .unsupportedRoute),
            ("mactools://app/search?=value", .unsupportedURLComponents),
            ("mactools://app/settings#private", .unsupportedURLComponents),
            ("mactools://user@app/settings", .unsupportedURLComponents),
            ("mactools://app:/settings", .unsupportedURLComponents),
            ("mactools://app:42/settings", .unsupportedURLComponents)
        ]

        for (urlString, expectedError) in cases {
            let url = try XCTUnwrap(URL(string: urlString))
            XCTAssertEqual(
                AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
                .failure(expectedError),
                "Unexpected parser result for \(urlString)"
            )
        }
    }

    func testParserRejectsOversizedPublicURL() throws {
        let query = String(repeating: "x", count: AppDeepLinkParser.maximumURLByteCount)
        let url = try XCTUnwrap(URL(string: "mactools://app/search?metadata=\(query)"))

        XCTAssertEqual(
            AppDeepLinkParser.parse(url, acceptedSchemes: ["mactools"]),
            .failure(.oversizedInput)
        )
    }

    func testColdLaunchQueueDrainsInArrivalOrderAfterPluginInitialization() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in XCTFail("Unexpected Finder Sync delegation") }
        )
        let general = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let plugin = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/fan-control")
        )

        XCTAssertEqual(router.handle(general), .queued(.settings(.general)))
        XCTAssertEqual(
            router.handle(plugin),
            .queued(.settings(.pluginConfiguration("fan-control")))
        )
        XCTAssertTrue(requests.isEmpty)

        let drained = router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { $0 == "fan-control" }
        )

        XCTAssertEqual(
            drained,
            [
                .handled(.settings(.general)),
                .handled(.settings(.pluginConfiguration("fan-control")))
            ]
        )
        XCTAssertEqual(
            requests,
            [
                .settings(.general),
                .settings(.pluginConfiguration("fan-control"))
            ]
        )
    }

    func testUnavailablePluginIsRejectedWhenColdLaunchQueueDrains() throws {
        var requests: [AppPresentationRequest] = []
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let url = try XCTUnwrap(
            URL(string: "mactools://app/settings/plugins/not-installed")
        )

        XCTAssertEqual(
            router.handle(url),
            .queued(.settings(.pluginConfiguration("not-installed")))
        )
        XCTAssertEqual(
            router.activate(
                presentationHandler: { requests.append($0) },
                isPluginConfigurationAvailable: { _ in false }
            ),
            [.rejected(.unavailablePlugin("not-installed"))]
        )
        XCTAssertTrue(requests.isEmpty)
    }

    func testPendingDirectActionAndPresetAliasShareCanonicalIdentity() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let presetID = UUID(uuidString: "7B420000-0000-4000-8000-000000000010")!
        let direct = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/aliased")
        )
        let preset = try XCTUnwrap(
            URL(string: "mactools://app/presets/\(presetID.uuidString)")
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "aliased")
        )
        var handledRequests: [ActionRunLinkRequest] = []
        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(reference) },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )

        XCTAssertEqual(router.handle(direct), .queuedAction(.direct(reference.key)))
        XCTAssertEqual(router.handle(preset), .rejected(.actionAlreadyRunning))
        await router.waitUntilIdle()

        XCTAssertEqual(handledRequests, [.direct(reference.key)])
    }

    func testQueueOverflowDoesNotReserveRejectedActionIdentity() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            maximumPendingDeepLinks: 1,
            rightClickHandler: { _ in }
        )
        let navigation = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/retry")
        )
        let reference = ActionReference(
            key: ActionKey(providerID: "test-provider", actionID: "retry")
        )
        var handledRequests: [ActionRunLinkRequest] = []

        XCTAssertEqual(router.handle(navigation), .queued(.settings(.general)))
        XCTAssertEqual(router.handle(action), .rejected(.pendingQueueFull))

        router.activate(
            presentationHandler: { _ in },
            isPluginConfigurationAvailable: { _ in true },
            actionIdentityResolver: { _ in .success(reference) },
            actionHandler: { request, _ in
                handledRequests.append(request)
                return .completed
            }
        )
        XCTAssertEqual(router.handle(action), .queuedAction(.direct(reference.key)))
        await router.waitUntilIdle()

        XCTAssertEqual(handledRequests, [.direct(reference.key)])
    }

    func testHandedOffActionRejectsDuplicateAsAlreadyRunningWithoutBlockingNavigation() async throws {
        let router = AppURLRouter(
            acceptedURLSchemes: ["mactools"],
            rightClickHandler: { _ in }
        )
        let action = try XCTUnwrap(
            URL(string: "mactools://app/actions/test-provider/continuing")
        )
        let settings = try XCTUnwrap(URL(string: "mactools://app/settings/general"))
        var requests: [AppPresentationRequest] = []
        var duplicateResult: AppURLHandlingResult?
        var continuingTask: Task<Void, Never>?
        var executionCompletion: Task<Void, Never>?
        router.activate(
            presentationHandler: { requests.append($0) },
            isPluginConfigurationAvailable: { _ in true },
            actionHandler: { _, _ in
                let completion = Task<Void, Never> {
                    try? await Task.sleep(for: .seconds(60))
                }
                executionCompletion = completion
                continuingTask = Task.detached {
                    await MainActor.run {
                        duplicateResult = router.handle(action)
                    }
                }
                return .continuing(until: completion)
            }
        )

        XCTAssertEqual(
            router.handle(action),
            .queuedAction(
                .direct(ActionKey(providerID: "test-provider", actionID: "continuing"))
            )
        )
        await router.waitUntilIdle()

        XCTAssertEqual(router.handle(settings), .handled(.settings(.general)))
        await continuingTask?.value
        executionCompletion?.cancel()
        XCTAssertEqual(requests, [.settings(.general)])
        XCTAssertEqual(duplicateResult, .rejected(.actionAlreadyRunning))
    }

}
