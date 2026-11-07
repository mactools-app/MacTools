import Carbon.HIToolbox
import CoreGraphics

struct QuitProtectionInputRouting {
    private var commandWasDown = false
    private(set) var commandIsEligible = false

    mutating func reset(commandIsDown: Bool) {
        commandWasDown = commandIsDown
        commandIsEligible = false
    }

    mutating func observeModifiers(commandIsDown: Bool, beganWithLocalCommandKey: Bool) {
        if !commandIsDown {
            reset(commandIsDown: false)
        } else if !commandWasDown {
            commandWasDown = true
            commandIsEligible = beganWithLocalCommandKey
        }
    }

    mutating func invalidate() {
        commandIsEligible = false
    }

    mutating func observeKeyDown(keyCode: UInt16, flags: CGEventFlags, isQuit: Bool, isLocal: Bool) -> Bool {
        if keyCode == kVK_Tab, flags == .maskCommand || flags == [.maskCommand, .maskShift] {
            invalidate()
        }
        return isQuit && isLocal && commandIsEligible
    }

    static func matchesDestination(
        _ pid: Int32, frontmostPID: Int32?, windowSwitcherIsVisible: Bool
    ) -> Bool {
        !windowSwitcherIsVisible && frontmostPID == pid
    }
}
