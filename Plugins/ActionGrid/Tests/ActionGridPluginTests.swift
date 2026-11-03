import AppKit
import MacToolsPluginKit
import XCTest
@testable import ActionGridPlugin

@MainActor
final class ActionGridPluginTests: XCTestCase {

    func testActionSelectionMustRemainVisibleAfterFiltering() {
        let first = ActionSurfaceCatalogItem(
            reference: ActionReference(
                key: ActionKey(providerID: "one", actionID: "run")
            ),
            title: "First",
            subtitle: nil,
            ownerTitle: "One",
            systemImage: "1.circle",
            availability: .available,
            isSafe: true
        )
        let second = ActionSurfaceCatalogItem(
            reference: ActionReference(
                key: ActionKey(providerID: "two", actionID: "run")
            ),
            title: "Second",
            subtitle: nil,
            ownerTitle: "Two",
            systemImage: "2.circle",
            availability: .available,
            isSafe: true
        )

        XCTAssertTrue(ActionGridActionSelectionPolicy.contains(
            first.reference,
            in: [first, second]
        ))
        XCTAssertFalse(ActionGridActionSelectionPolicy.contains(
            first.reference,
            in: [second]
        ))
        XCTAssertFalse(ActionGridActionSelectionPolicy.contains(nil, in: [first]))
    }

    func testShowActionIsForegroundOnlyExternallyEligibleAndPresentsSavedEntries() async throws {
        let storage = ActionGridTestStorage()
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: storage)
        )
        let target = ActionReference(key: ActionKey(providerID: "target", actionID: "run"))
        var presented: [ActionGridPresentationEntry] = []
        var presentationSource: ActionExecutionSource?
        var openedOwner: ActionReference?
        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            openOwner: {
                openedOwner = $0
                return true
            },
            canPresent: { true },
            present: { entries, source in
                presented = entries
                presentationSource = source
                return true
            }
        )
        XCTAssertTrue(plugin.store.add(reference: target, in: nil, at: 8))
        let definition = try XCTUnwrap(plugin.actionDefinitions.first)

        XCTAssertEqual(definition.key, ActionGridPlugin.showActionKey)
        XCTAssertEqual(definition.capabilities, [.foregroundInteractive, .opensInterface])
        XCTAssertEqual(definition.externalInvocationPolicy, .allowed)
        XCTAssertTrue(plugin.actionAvailability(for: ActionReference(key: definition.key)).isAvailable)

        let handle = try plugin.beginAction(
            ActionInvocation(
                reference: ActionReference(key: definition.key),
                source: .trackpadGesture,
                mode: .foreground
            )
        )
        let result = await handle.result()
        XCTAssertEqual(result, .succeeded())
        XCTAssertEqual(presented.map(\.reference), [target])
        XCTAssertEqual(presented.map(\.slotIndex), [8])
        XCTAssertEqual(presentationSource, .trackpadGesture)
        XCTAssertTrue(plugin.openOwner(for: target))
        XCTAssertEqual(openedOwner, target)
        XCTAssertEqual(
            plugin.actionSurfaceAssignmentSummary(for: target)?.detail,
            "第 9 个条目"
        )
    }

    func testShowActionIsUnavailableWithoutEntriesOrHostPresenterAndSelfEntryIsNeverPresented() async throws {
        let plugin = ActionGridPlugin(
            context: PluginRuntimeContext(pluginID: "action-grid", storage: ActionGridTestStorage())
        )
        let showReference = ActionReference(key: ActionGridPlugin.showActionKey)
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)

        plugin.actionGridHostContext = ActionGridHostContext(
            catalog: { [] },
            item: { _ in nil },
            migrate: { $0 },
            canPresent: { true },
            present: { _, _ in XCTFail("Presenter should not be called"); return false }
        )
        XCTAssertTrue(plugin.store.add(reference: showReference))
        XCTAssertFalse(plugin.actionAvailability(for: showReference).isAvailable)
        let handle = try plugin.beginAction(
            ActionInvocation(reference: showReference, source: .manual, mode: .foreground)
        )
        let result = await handle.result()
        XCTAssertEqual(result, .failed(message: "无法显示操作网格。"))
    }
}
