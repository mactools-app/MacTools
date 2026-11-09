import Foundation
import MacToolsPluginKit
import XCTest

final class ActionModelsTests: XCTestCase {
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
