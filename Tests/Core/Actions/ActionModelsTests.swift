import Foundation
import MacToolsPluginKit
import XCTest

final class ActionModelsTests: XCTestCase {
    @MainActor
    func testPercentageLabelFollowsAppLanguage() {
        let originalPreference = UserDefaults.standard.string(forKey: PluginRuntimeLocalization.preferenceUserDefaultsKey)
        defer { PluginRuntimeLocalization.source.setPreference(originalPreference) }

        PluginRuntimeLocalization.source.setPreference("en")
        let english = ActionPercentage.label(23)
        PluginRuntimeLocalization.source.setPreference("ar")
        let arabic = ActionPercentage.label(23)
        let expected = 0.23.formatted(.percent.precision(.fractionLength(0)).locale(PluginRuntimeLocalization.locale))
        XCTAssertEqual(arabic, expected)
        XCTAssertNotEqual(arabic, english)
    }

    func testExactDDCRoundingUsesRawRatioAtHalfPercentage() {
        XCTAssertNil(ActionPercentage.hardwareStep(for: 0.57, maximum: 40))
        XCTAssertEqual(ActionPercentage.hardwareStep(for: 0.58, maximum: 40), 23)
        XCTAssertTrue(ActionPercentage.matchesHardwareLevel(raw: 23, maximum: 40, requested: 0.58))
        XCTAssertFalse(ActionPercentage.matchesHardwareLevel(raw: 23, maximum: 40, requested: 0.57))
    }

    func testDisplayCatalogLabelsSurviveReorderingAndDisconnect() {
        let definition = ActionDefinition(
            key: .init(providerID: "fixture", actionID: "set"),
            title: "Set Level", description: "", systemImage: "display"
        )
        func display(_ id: UInt32, main: Bool) -> DisplayInfo {
            DisplayInfo(id: id, name: "Monitor", isBuiltin: false, isMain: main,
                        vendorNumber: 1, modelNumber: 2, serialNumber: id)
        }
        func labels(_ displays: [DisplayInfo]) -> [ActionReference: String] {
            Dictionary(uniqueKeysWithValues: DisplayActionTarget.catalogEntries(
                for: displays, definition: definition, identifier: { "fixture-\($0)" }
            ).map { ($0.reference, $0.subtitle ?? "") })
        }
        let original = labels([display(1, main: true), display(2, main: false)])
        let reordered = labels([display(2, main: true), display(1, main: false)])
        XCTAssertEqual(original, reordered)
        XCTAssertEqual(Set(original.values).count, 2)
        let single = labels([display(2, main: true)])
        XCTAssertEqual(single.count, 1)
        for (reference, label) in single {
            XCTAssertEqual(label, original[reference])
        }
    }

    func testPercentageAcceptsLocalizedDecimalDigits() throws {
        let parameters = try ActionParameterSet([ActionPercentage.parameterID: .integer(50)])
        let template = ActionReference(key: ActionKey(providerID: "fixture", actionID: "set"), parameters: parameters)

        let configured = try XCTUnwrap(ActionPercentage.setting(" ٧٥ ", in: template))
        XCTAssertEqual(ActionPercentage.value(in: configured), 75)
        XCTAssertNil(ActionPercentage.setting("١٠١", in: template))
        XCTAssertNil(ActionPercentage.setting("½", in: template))
    }

    func testLegacyActionReferenceDecodesAsSchemaVersionOne() throws {
        let payload = Data(
            #"{"key":{"providerID":"test-provider","actionID":"toggle"},"parameters":[]}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ActionReference.self, from: payload)
        let encoded = try JSONEncoder().encode(decoded)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("schemaVersion"))
    }

    func testParameterSetCanonicalizesOrderAndRoundTripsDeterministically() throws {
        let first = try ActionParameterSet(entries: [
            .init(name: "target", value: .string("internal")),
            .init(name: "enabled", value: .boolean(true)),
        ])
        let second = try ActionParameterSet(entries: [
            .init(name: "enabled", value: .boolean(true)),
            .init(name: "target", value: .string("internal")),
        ])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.entries.map(\.name), ["enabled", "target"])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(first)
        XCTAssertEqual(encoded, try encoder.encode(second))
        XCTAssertEqual(try JSONDecoder().decode(ActionParameterSet.self, from: encoded), first)
    }

    func testParameterSetRejectsDuplicatesAndOversizedSensitiveValues() throws {
        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(name: "value", value: .integer(1)),
                .init(name: "value", value: .integer(2)),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .duplicateName("value"))
        }

        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(
                    name: "secret",
                    value: .string(String(repeating: "x", count: ActionParameterSet.maximumStringByteCount + 1))
                ),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .stringTooLong("secret"))
        }
    }

    func testParameterSchemaCarriesPrivacyAndPortabilityMetadata() {
        let parameter = ActionParameterDefinition(
            id: "bookmark",
            title: "文件",
            kind: .string,
            privacy: .sensitive,
            portability: .localOnly
        )

        XCTAssertEqual(parameter.privacy, .sensitive)
        XCTAssertEqual(parameter.portability, .localOnly)
    }

    func testNonFiniteDoubleCannotEnterCanonicalIdentity() {
        XCTAssertThrowsError(
            try ActionParameterSet(entries: [
                .init(name: "value", value: .double(.infinity)),
            ])
        ) { error in
            XCTAssertEqual(error as? ActionParameterSetError, .nonFiniteNumber("value"))
        }
    }

    func testAppIntentExposureSurfaceAndExecutionSourceRoundTrip() throws {
        let surfaceData = try JSONEncoder().encode(ActionExposureSurface.appIntents)
        XCTAssertEqual(
            try JSONDecoder().decode(ActionExposureSurface.self, from: surfaceData),
            .appIntents
        )

        let invocation = ActionInvocation(
            reference: ActionReference(
                key: ActionKey(providerID: "test-provider", actionID: "run")
            ),
            source: .appIntent,
            mode: .background
        )
        let invocationData = try JSONEncoder().encode(invocation)

        XCTAssertEqual(
            try JSONDecoder().decode(ActionInvocation.self, from: invocationData),
            invocation
        )
    }
}
