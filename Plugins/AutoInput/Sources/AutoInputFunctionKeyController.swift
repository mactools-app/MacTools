import Foundation
import IOKit.hidsystem

/// Reads and writes the system-wide "Use F1, F2, etc. as standard function keys" setting.
///
/// The setting lives in the user's global defaults domain and applies to the whole
/// keyboard, so per-application behavior is emulated by rewriting it as applications
/// change and restoring the original value when no rule applies.
///
/// Writing the preference alone is not enough: the HID system only re-reads it at login,
/// while System Settings pushes the change to `HIDFKeyMode` right away. The controller
/// therefore updates the live HID parameter and keeps the preference in sync so the
/// choice survives a restart and matches what System Settings reports.
///
/// The live HID mode and the persisted preference can drift apart, for example when the
/// preference is rewritten without a matching HID update or when a flush never reaches
/// disk. A caller that only compares the preference can therefore conclude that nothing
/// has to be done while the top row still uses the other mode, so
/// `setStandardFunctionKeysEnabled(_:)` always pushes the requested value to the HID
/// system and only skips the preference write when it is already up to date.
@MainActor
protocol AutoInputFunctionKeyControlling: AnyObject {
    var isStandardFunctionKeysEnabled: Bool { get }

    @discardableResult
    func setStandardFunctionKeysEnabled(_ isEnabled: Bool) -> Bool
}

@MainActor
final class SystemAutoInputFunctionKeyController: AutoInputFunctionKeyControlling {
    private static let fnStatePreferenceKey = "com.apple.keyboard.fnState" as CFString
    private static let fnModeKey = kIOHIDFKeyModeKey as CFString
    private static let changeNotificationName = Notification.Name(
        "com.apple.keyboard.fnstatedidchange"
    )

    private var hidSystemConnection: io_connect_t = 0

    deinit {
        if hidSystemConnection != 0 {
            IOServiceClose(hidSystemConnection)
        }
    }

    var isStandardFunctionKeysEnabled: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value: Any? = CFPreferencesCopyValue(
            Self.fnStatePreferenceKey,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        switch value {
        case let value as Bool: return value
        case let value as NSNumber: return value.boolValue
        default: return false
        }
    }

    @discardableResult
    func setStandardFunctionKeysEnabled(_ isEnabled: Bool) -> Bool {
        // The HID write is the only step that changes the live behavior, so it is never
        // skipped: trusting the preference here is what leaves the top row on the wrong
        // mode when the two values have drifted apart.
        guard applyToHIDSystem(isEnabled) else { return false }
        guard persistStandardFunctionKeys(isEnabled) else { return true }
        // Nudge observers the same way System Settings reports the change so the
        // new state is picked up without reopening the keyboard pane.
        DistributedNotificationCenter.default().postNotificationName(
            Self.changeNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return true
    }

    /// Applies the top-row behavior to the running HID system so it takes effect at once.
    private func applyToHIDSystem(_ isEnabled: Bool) -> Bool {
        if writeHIDMode(isEnabled) { return true }
        // A cached connection can go stale after sleep, a driver restart, or a HID system
        // relaunch. Reconnecting once keeps one transient failure from disabling every
        // later write for the rest of the session.
        invalidateHIDConnection()
        return writeHIDMode(isEnabled)
    }

    private func writeHIDMode(_ isEnabled: Bool) -> Bool {
        guard let connection = hidConnection() else { return false }
        let value = (isEnabled ? 1 : 0) as CFNumber
        let result = IOHIDSetCFTypeParameter(connection, Self.fnModeKey, value)
        guard result == KERN_SUCCESS else {
            invalidateHIDConnection()
            return false
        }
        return true
    }

    /// Mirrors the value into the global preference so the choice survives a restart.
    /// Returns whether the stored value actually changed.
    private func persistStandardFunctionKeys(_ isEnabled: Bool) -> Bool {
        guard isStandardFunctionKeysEnabled != isEnabled else { return false }
        CFPreferencesSetValue(
            Self.fnStatePreferenceKey,
            isEnabled ? kCFBooleanTrue : kCFBooleanFalse,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        // A failed flush only affects persistence across restarts; the live mode is
        // already applied, so it must not turn this change into an error.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return true
    }

    private func hidConnection() -> io_connect_t? {
        if hidSystemConnection != 0 {
            return hidSystemConnection
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == kIOReturnSuccess,
              connection != 0 else {
            return nil
        }
        hidSystemConnection = connection
        return connection
    }

    private func invalidateHIDConnection() {
        guard hidSystemConnection != 0 else { return }
        IOServiceClose(hidSystemConnection)
        hidSystemConnection = 0
    }
}
