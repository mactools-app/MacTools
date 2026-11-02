import Foundation
import XCTest
@testable import VoiceControlPlugin

final class VoiceTranscriptTests: XCTestCase {
    func testOverlappingAndLateFragmentsKeepIndependentSpeakers() {
        var captions = VoiceTranscript()
        captions.append("Set", speaker: .user, start: 100, end: 300)
        captions.append("Sure", speaker: .assistant, start: 350, end: 500)
        captions.append(" brightness", speaker: .user, start: 400, end: 700)
        captions.append(".", speaker: .assistant, start: 500, end: 600)
        captions.append(" to 35%", speaker: .user, start: 700, end: 1_000)
        captions.append("Thanks", speaker: .user, start: 5_000, end: 5_300)
        captions.append(" Done.", speaker: .assistant, start: 800, end: 1_000)
        XCTAssertEqual(captions.turns.map(\.speaker), [.user, .assistant, .user])
        XCTAssertEqual(captions.turns.map(\.text), ["Set brightness to 35%", "Sure. Done.", "Thanks"])
        XCTAssertEqual(captions.fragments.count, 7)
        XCTAssertEqual(captions.fragments.last?.start, 800)
    }

    func testLocalSpeechBufferIsOrderedBoundedAndConsumedOnce() throws {
        var pending = VoicePendingInput()
        try pending.append(Data([1, 2]))
        try pending.append(Data([3, 4]))
        XCTAssertEqual(pending.take(), [Data([1, 2]), Data([3, 4])])
        XCTAssertTrue(pending.take().isEmpty)
        XCTAssertThrowsError(try pending.append(Data(count: 24_000 * 2 * 15 + 1)))
        XCTAssertTrue(pending.take().isEmpty)
    }
}
