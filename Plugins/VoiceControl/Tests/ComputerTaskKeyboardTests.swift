import Carbon
import Foundation
import XCTest
@testable import VoiceControlPlugin

@MainActor
final class ComputerTaskKeyboardTests: XCTestCase {
    func testLetterShortcutsUseTheSelectedLayoutWithoutChangingInputSources() throws {
        let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        for identifier in ["com.apple.keylayout.US", "com.apple.keylayout.French", "com.apple.keylayout.German"] {
            guard let source = sources.first(where: { sourceID($0) == identifier }),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                throw XCTSkip("This host does not have the required keyboard layout")
            }
            let layout = ComputerTaskKeyboardLayout(data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data,
                keyboardType: UInt32(LMGetKbdType()), sourceID: identifier, inputSourceID: identifier)
            for letter in ["q", "z", "a"] {
                let chord = try ComputerTaskKeyChord(["command", letter], layout: layout)
                XCTAssertEqual(layout.character(chord.keyCode, command: true), letter)
            }
            let shifted = try ComputerTaskKeyChord(["command", "shift", "z"], layout: layout)
            XCTAssertTrue(shifted.flags.contains(.maskShift))
            XCTAssertEqual(layout.character(shifted.keyCode, command: true), "z")
        }
    }

    private func sourceID(_ source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
