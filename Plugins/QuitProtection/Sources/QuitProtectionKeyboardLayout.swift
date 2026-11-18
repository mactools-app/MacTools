import Carbon.HIToolbox
import Foundation

struct QuitProtectionKeyboardLayout: Equatable {
    let inputSourceID: String
    let layoutSourceID: String
    let data: Data
    let keyboardType: UInt32

    @MainActor
    static func current(keyboardType: UInt32) -> Self? {
        guard let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let selected = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let inputID = identifier(input) else { return nil }
        let source = TISGetInputSourceProperty(selected, kTISPropertyUnicodeKeyLayoutData) != nil
            ? selected : TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source, let layoutID = identifier(source),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return .init(inputSourceID: inputID, layoutSourceID: layoutID, data: data, keyboardType: keyboardType)
    }

    private static func identifier(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    func isQuitKey(_ keyCode: UInt16) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count >= MemoryLayout<UCKeyboardLayout>.size else { return false }
            var dead: UInt32 = 0
            var length = 0
            var units = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode,
                UInt16(kUCKeyActionDown), UInt32(cmdKey) >> 8, keyboardType,
                UInt32(kUCKeyTranslateNoDeadKeysMask), &dead, units.count, &length, &units)
            return status == noErr && String(utf16CodeUnits: units, count: length).lowercased() == "q"
        }
    }
}
