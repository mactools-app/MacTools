import Foundation
import MacToolsPluginKit
import XCTest
@testable import MacTools

@MainActor
final class MarketplacePluginSetupPresentationTests: XCTestCase {
    func testLoadedPluginHasNoDiagnosticRegion() {
        let presentation = makePresentation()

        XCTAssertTrue(presentation.issues.isEmpty)
    }

    func testInstalledPackageWithoutRuntimeRequiresRecheckInsteadOfReadySettings() {
        let presentation = makePresentation(isRuntimeLoaded: false)

        XCTAssertEqual(presentation.issues.map(\.kind), [.runtimeUnavailable])
        XCTAssertEqual(presentation.issues.first?.action?.intent, .recheckRequirements)
    }

    func testMissingPermissionsKeepExistingCardAndExplicitRepairIdentity() throws {
        let card = makeCard(pluginID: "example", permissionID: "accessibility")
        let unrelatedCard = makeCard(pluginID: "other", permissionID: "calendar")
        let presentation = makePresentation(cards: [unrelatedCard, card, card])
        let issue = try XCTUnwrap(presentation.issues.first)

        XCTAssertEqual(presentation.issues.count, 1)
        XCTAssertEqual(issue.permissionCard?.id, card.id)
        XCTAssertEqual(issue.permissionCard?.statusTone, .caution)
        XCTAssertEqual(issue.action?.intent, .permission(pluginID: "example", permissionID: "accessibility"))
    }

    func testRestartAndIsolationDoNotAdvertisePackageRecheckAsRuntimeRecovery() {
        let restart = makePresentation(state: .restartRequired)
        XCTAssertEqual(restart.issues.map(\.kind), [.restart])
        XCTAssertNil(restart.issues.first?.action)

        let isolation = makePresentation(isRuntimeLoaded: false, isolationFailure: "Runtime failure", hasSettings: false)
        XCTAssertEqual(isolation.issues.map(\.kind), [.runtimeIsolation])
        XCTAssertNil(isolation.issues.first?.action)
    }

    func testRequirementFailureOffersExistingRecheckWithoutInstalledPackage() {
        let presentation = makePresentation(state: .incompatible("Required application is missing"), packageInstalled: false,
                                            isRuntimeLoaded: false, hasSettings: false)

        XCTAssertEqual(presentation.issues.map(\.kind), [.incompatible])
        XCTAssertEqual(presentation.issues.first?.action?.intent, .recheckRequirements)
    }

    func testUninstalledCatalogFallbackHasNoRuntimeDiagnostic() {
        let presentation = makePresentation(state: .available, packageInstalled: false,
                                            isRuntimeLoaded: false, hasSettings: false)

        XCTAssertTrue(presentation.issues.isEmpty)
    }

    func testFailedInstalledPackagePreservesLoadReasonAndRecheck() throws {
        let reason = "Plugin bundle could not be loaded"
        let presentation = makePresentation(state: .failed(reason), isRuntimeLoaded: false, hasSettings: false)
        let issue = try XCTUnwrap(presentation.issues.first)

        XCTAssertEqual(presentation.issues.map(\.kind), [.loadFailure])
        XCTAssertEqual(issue.detail, reason)
        XCTAssertEqual(issue.action?.intent, .recheckRequirements)
    }

    private func makePresentation(
        state: PluginManagementItem.State = .installed,
        packageInstalled: Bool = true,
        isRuntimeLoaded: Bool = true,
        isolationFailure: String? = nil,
        hasSettings: Bool = true,
        cards: [PluginPermissionCard] = []
    ) -> MarketplacePluginSetupPresentation {
        MarketplacePluginSetupPresentation(
            item: PluginManagementItem(
                id: "example", title: "Example", summary: nil, version: "1.0.0", state: state,
                packageURL: packageInstalled ? URL(fileURLWithPath: "/tmp/Example.mactoolsplugin") : nil,
                requiresRestartToFullyUnload: false, releaseNotesURL: nil
            ),
            missingPermissionCards: cards, runtimeIsolationFailure: isolationFailure,
            isRuntimeLoaded: isRuntimeLoaded, hasSettings: hasSettings
        )
    }

    private func makeCard(pluginID: String, permissionID: String) -> PluginPermissionCard {
        PluginPermissionCard(
            id: "\(pluginID).permission.\(permissionID)", pluginID: pluginID, permissionID: permissionID,
            title: "Permission", description: "Required permission", iconSystemImage: "accessibility",
            statusText: "Missing", statusSystemImage: "exclamationmark.triangle", statusTone: .caution,
            footnote: "Existing guidance", buttonTitle: "Grant permission"
        )
    }
}
