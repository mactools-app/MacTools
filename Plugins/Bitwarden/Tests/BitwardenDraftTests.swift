@testable import BitwardenPlugin
import Foundation
import XCTest

final class BitwardenDraftTests: XCTestCase {
    func testEditingPreservesCustomFieldsAndSiteMatching() throws {
        let input = Data(#"{"id":"fixture","type":1,"name":"Login","reprompt":0,"fields":[{"name":"Extra","type":1,"value":"fixture-value"}],"login":{"username":"name","uris":[{"uri":"https://example.test","match":2}]}}"#.utf8)
        var draft = try BitwardenDraft(itemID: "fixture", data: input)
        draft.fields["username"] = "updated"
        let decoded = try XCTUnwrap(Data(base64Encoded: draft.encoded()))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        let login = try XCTUnwrap(record["login"] as? [String: Any])
        XCTAssertEqual(login["username"] as? String, "updated")
        XCTAssertEqual((login["uris"] as? [[String: Any]])?.first?["match"] as? Int, 2)
        XCTAssertEqual((record["fields"] as? [[String: Any]])?.first?["value"] as? String, "fixture-value")
    }

    func testRepromptItemCannotBeOpenedOrSearchedByPrivateFields() throws {
        let input = Data(#"{"id":"fixture","type":1,"name":"Protected","reprompt":1,"login":{"username":"private-fixture"}}"#.utf8)
        let item = try JSONDecoder().decode(BitwardenItem.self, from: input)
        XCTAssertTrue(item.matches("Protected"))
        XCTAssertFalse(item.matches("private-fixture"))
        XCTAssertThrowsError(try BitwardenDraft(itemID: item.id, data: input))
    }
}
