import Carbon
import MacToolsPluginKit

enum GlobalShortcutRegistrationError: Error, Equatable {
    case invalidBinding
    case system(OSStatus)
}

enum GlobalShortcutRegistrationStatus: Equatable {
    case registered
    case failed(GlobalShortcutRegistrationError)
}

@MainActor
protocol CarbonHotKeyRegistering: AnyObject {
    func register(
        binding: ShortcutBinding,
        signature: OSType,
        carbonID: UInt32
    ) -> Result<EventHotKeyRef, GlobalShortcutRegistrationError>
    func unregister(_ reference: EventHotKeyRef)
}

@MainActor
final class SystemCarbonHotKeyRegistrar: CarbonHotKeyRegistering {
    func register(
        binding: ShortcutBinding,
        signature: OSType,
        carbonID: UInt32
    ) -> Result<EventHotKeyRef, GlobalShortcutRegistrationError> {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode),
            binding.modifiers.carbonFlags,
            EventHotKeyID(signature: signature, id: carbonID),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            return .failure(.system(status))
        }
        return .success(reference)
    }

    func unregister(_ reference: EventHotKeyRef) {
        UnregisterEventHotKey(reference)
    }
}

enum MacToolsReservedShortcutBindings {
    private static let settingsNavigationBindings = Set([kVK_UpArrow, kVK_DownArrow].map {
        ShortcutBinding(keyCode: UInt16($0), modifiers: [.control, .command])
    })

    static func requiresConflictWarning(for binding: ShortcutBinding) -> Bool {
        !settingsNavigationBindings.contains(binding)
            && CommonApplicationShortcutBindings.requiresConflictWarning(for: binding)
    }

    static func validationError(
        for binding: ShortcutBinding
    ) -> ShortcutValidationError? {
        guard settingsNavigationBindings.contains(binding) else {
            return nil
        }

        return .duplicate(ownerDescription: AppMetadata.appName)
    }
}

@MainActor
final class GlobalShortcutManager {
    struct Registration: Equatable {
        let shortcutID: String
        let binding: ShortcutBinding
    }

    private struct RegisteredHotKey {
        let binding: ShortcutBinding
        let reference: EventHotKeyRef
        let carbonID: UInt32
        var shortcutIDs: [String]
    }

    private static let signature: OSType = 0x4D43544C

    var onShortcutTriggered: ((String) -> Void)?
    var onShortcutReleased: ((String) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registeredHotKeys: [ShortcutBinding: RegisteredHotKey] = [:]
    private var shortcutIDsByCarbonID: [UInt32: [String]] = [:]
    private var nextCarbonID: UInt32 = 1
    private let registrar: any CarbonHotKeyRegistering

    private(set) var registrationStatuses: [String: GlobalShortcutRegistrationStatus] = [:]

    #if DEBUG
    private(set) var debugRegistrationsForTests: [Registration] = []
    #endif

    init(registrar: any CarbonHotKeyRegistering = SystemCarbonHotKeyRegistrar()) {
        self.registrar = registrar
        installHandlerIfNeeded()
    }

    isolated deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    @discardableResult
    func updateBindings(
        _ registrations: [Registration]
    ) -> [String: GlobalShortcutRegistrationStatus] {
        installHandlerIfNeeded()

        #if DEBUG
        debugRegistrationsForTests = registrations
        #endif

        var statuses: [String: GlobalShortcutRegistrationStatus] = [:]
        let targetGroups = registrations.reduce(into: [ShortcutBinding: [String]]()) { result, registration in
            guard registration.binding.isValid else {
                statuses[registration.shortcutID] = .failed(.invalidBinding)
                return
            }

            if result[registration.binding]?.contains(registration.shortcutID) == true {
                return
            }

            result[registration.binding, default: []].append(registration.shortcutID)
        }

        for binding in Array(registeredHotKeys.keys) where targetGroups[binding] == nil {
            unregister(binding: binding)
        }

        for (binding, shortcutIDs) in targetGroups {
            if var existing = registeredHotKeys[binding] {
                existing.shortcutIDs = shortcutIDs
                registeredHotKeys[binding] = existing
                shortcutIDsByCarbonID[existing.carbonID] = shortcutIDs
                for shortcutID in shortcutIDs {
                    statuses[shortcutID] = .registered
                }
                continue
            }

            if let error = register(binding: binding, shortcutIDs: shortcutIDs) {
                for shortcutID in shortcutIDs {
                    statuses[shortcutID] = .failed(error)
                }
            } else {
                for shortcutID in shortcutIDs {
                    statuses[shortcutID] = .registered
                }
            }
        }
        registrationStatuses = statuses
        return statuses
    }

    #if DEBUG
    func triggerForTests(shortcutID: String) {
        onShortcutTriggered?(shortcutID)
    }
    #endif

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }

        let eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        // Register/listen on the event dispatcher target, matching Magnet and MASShortcut. In this
        // app's run loop, global hotkey events are not routed to `GetApplicationEventTarget()`, so
        // hotkeys can register successfully but never trigger callbacks.
        _ = eventTypes.withUnsafeBufferPointer { buffer in
            InstallEventHandler(
                GetEventDispatcherTarget(),
                Self.hotKeyHandler,
                buffer.count,
                buffer.baseAddress,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &handlerRef
            )
        }
    }

    private func register(
        binding: ShortcutBinding,
        shortcutIDs: [String]
    ) -> GlobalShortcutRegistrationError? {
        let carbonID = nextCarbonID
        nextCarbonID += 1

        let hotKeyReference: EventHotKeyRef
        switch registrar.register(
            binding: binding,
            signature: Self.signature,
            carbonID: carbonID
        ) {
        case let .success(reference):
            hotKeyReference = reference
        case let .failure(error):
            return error
        }

        registeredHotKeys[binding] = RegisteredHotKey(
            binding: binding,
            reference: hotKeyReference,
            carbonID: carbonID,
            shortcutIDs: shortcutIDs
        )
        shortcutIDsByCarbonID[carbonID] = shortcutIDs
        return nil
    }

    private func unregister(binding: ShortcutBinding) {
        guard let registered = registeredHotKeys.removeValue(forKey: binding) else {
            return
        }

        shortcutIDsByCarbonID.removeValue(forKey: registered.carbonID)
        registrar.unregister(registered.reference)
    }

    private func unregisterAll() {
        for binding in Array(registeredHotKeys.keys) {
            unregister(binding: binding)
        }
    }

    private func dispatchShortcut(carbonID: UInt32, isReleased: Bool) {
        guard let shortcutIDs = shortcutIDsByCarbonID[carbonID] else {
            return
        }

        for shortcutID in shortcutIDs {
            if isReleased {
                onShortcutReleased?(shortcutID)
            } else {
                onShortcutTriggered?(shortcutID)
            }
        }
    }

    private nonisolated static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard
            let event,
            let userData
        else {
            return OSStatus(eventNotHandledErr)
        }

        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        guard hotKeyID.signature == 0x4D43544C else {
            return OSStatus(eventNotHandledErr)
        }

        let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
        let isReleased = GetEventKind(event) == UInt32(kEventHotKeyReleased)

        // Carbon invokes this C callback outside Swift concurrency. Scheduling a
        // main-queue block avoids carrying that foreign callback's executor state
        // into SwiftUI presentation, while the strong capture keeps the manager
        // alive until delivery finishes.
        DispatchQueue.main.async {
            manager.dispatchShortcut(carbonID: hotKeyID.id, isReleased: isReleased)
        }

        return noErr
    }
}
