import Foundation
import ObjectiveC

private enum NightShiftObjectiveCABI {
    static func isBoolean(_ value: CChar) -> Bool {
        // Objective-C BOOL is encoded as C99 bool on arm64 and can be a signed
        // char on Intel. Both representations occupy one byte.
        value == CChar(66) || value == CChar(99) // B or c
    }
}

@MainActor
protocol NightShiftControlling {
    func getStatus() -> Bool
    func observedStatus() -> Bool?
    func setEnabled(_ enabled: Bool) -> Bool
}

extension NightShiftControlling {
    func observedStatus() -> Bool? { getStatus() }
}

@MainActor
protocol NightShiftCoreBrightnessCalling: AnyObject {
    func isEnabled() -> Bool?
    func setEnabled(_ enabled: Bool) -> Bool
}

@MainActor
final class CBNightShiftController: NightShiftControlling {
    private let client: (any NightShiftCoreBrightnessCalling)?

    init() {
        client = NightShiftCoreBrightnessClient.makeSystemClient()
    }

    init(client: (any NightShiftCoreBrightnessCalling)?) {
        self.client = client
    }

    func getStatus() -> Bool {
        client?.isEnabled() ?? false
    }

    func observedStatus() -> Bool? { client?.isEnabled() }

    func setEnabled(_ enabled: Bool) -> Bool {
        guard let client,
              client.setEnabled(enabled),
              client.isEnabled() == enabled else {
            return false
        }
        return true
    }
}

struct NightShiftStatusBufferLayout: Equatable {
    let byteCount: Int
    let alignment: Int
    let enabledOffset: Int

    static func resolve(argumentType: String) -> NightShiftStatusBufferLayout? {
        argumentType.withCString { encodedType in
            resolve(argumentType: encodedType)
        }
    }

    static func resolve(
        argumentType: UnsafePointer<CChar>
    ) -> NightShiftStatusBufferLayout? {
        let pointerMarker = CChar(94) // ^
        let structureMarker = CChar(123) // {
        let fieldSeparator = CChar(61) // =
        let terminator = CChar(0)

        guard argumentType.pointee == pointerMarker,
              argumentType.advanced(by: 1).pointee == structureMarker else {
            return nil
        }

        var separatorOffset = 2
        while separatorOffset < 1_024 {
            let value = argumentType.advanced(by: separatorOffset).pointee
            if value == fieldSeparator {
                break
            }
            guard value != terminator else {
                return nil
            }
            separatorOffset += 1
        }
        guard separatorOffset < 1_024 else {
            return nil
        }

        let firstField = argumentType.advanced(by: separatorOffset + 1)
        guard NightShiftObjectiveCABI.isBoolean(firstField.pointee) else {
            return nil
        }

        var firstSize = 0
        var firstAlignment = 0
        let secondField = NSGetSizeAndAlignment(
            firstField,
            &firstSize,
            &firstAlignment
        )
        guard firstSize > 0,
              firstAlignment > 0,
              NightShiftObjectiveCABI.isBoolean(secondField.pointee) else {
            return nil
        }

        var secondSize = 0
        var secondAlignment = 0
        _ = NSGetSizeAndAlignment(secondField, &secondSize, &secondAlignment)
        guard secondSize > 0, secondAlignment > 0 else {
            return nil
        }

        let enabledOffset = alignedOffset(firstSize, alignment: secondAlignment)
        var byteCount = 0
        var alignment = 0
        _ = NSGetSizeAndAlignment(
            argumentType.advanced(by: 1),
            &byteCount,
            &alignment
        )
        guard byteCount > enabledOffset,
              byteCount <= 4_096,
              alignment > 0,
              alignment <= 64 else {
            return nil
        }

        return NightShiftStatusBufferLayout(
            byteCount: byteCount,
            alignment: alignment,
            enabledOffset: enabledOffset
        )
    }

    private static func alignedOffset(_ offset: Int, alignment: Int) -> Int {
        ((offset + alignment - 1) / alignment) * alignment
    }
}

@MainActor
final class NightShiftCoreBrightnessClient: NightShiftCoreBrightnessCalling {
    private typealias GetStatusImplementation = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutableRawPointer
    ) -> ObjCBool
    private typealias SetEnabledImplementation = @convention(c) (
        AnyObject,
        Selector,
        ObjCBool
    ) -> ObjCBool
    private typealias SupportedImplementation = @convention(c) (
        AnyObject,
        Selector
    ) -> ObjCBool

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreBrightness.framework"
    private static let clientClassName = "CBBlueLightClient"

    private let client: NSObject
    private let statusSelector: Selector
    private let setEnabledSelector: Selector
    private let statusImplementation: GetStatusImplementation
    private let setEnabledImplementation: SetEnabledImplementation
    private let statusLayout: NightShiftStatusBufferLayout

    private init(
        client: NSObject,
        statusSelector: Selector,
        setEnabledSelector: Selector,
        statusImplementation: @escaping GetStatusImplementation,
        setEnabledImplementation: @escaping SetEnabledImplementation,
        statusLayout: NightShiftStatusBufferLayout
    ) {
        self.client = client
        self.statusSelector = statusSelector
        self.setEnabledSelector = setEnabledSelector
        self.statusImplementation = statusImplementation
        self.setEnabledImplementation = setEnabledImplementation
        self.statusLayout = statusLayout
    }

    static func makeSystemClient() -> NightShiftCoreBrightnessClient? {
        guard let framework = Bundle(path: frameworkPath),
              framework.isLoaded || framework.load(),
              let clientClass = NSClassFromString(clientClassName) as? NSObject.Type else {
            return nil
        }

        let statusSelector = NSSelectorFromString("getBlueLightStatus:")
        let setEnabledSelector = NSSelectorFromString("setEnabled:")
        guard let statusMethod = class_getInstanceMethod(clientClass, statusSelector),
              let setEnabledMethod = class_getInstanceMethod(clientClass, setEnabledSelector),
              method_getNumberOfArguments(statusMethod) == 3,
              method_getNumberOfArguments(setEnabledMethod) == 3,
              methodReturnsObjectiveCBoolean(statusMethod),
              methodReturnsObjectiveCBoolean(setEnabledMethod),
              methodArgumentIsObjectiveCBoolean(setEnabledMethod, index: 2),
              let statusArgumentType = method_copyArgumentType(statusMethod, 2) else {
            return nil
        }
        defer { free(statusArgumentType) }

        guard let statusLayout = NightShiftStatusBufferLayout.resolve(
            argumentType: UnsafePointer(statusArgumentType)
        ) else {
            return nil
        }

        let client = clientClass.init()
        if let supportedMethod = class_getInstanceMethod(
            clientClass,
            NSSelectorFromString("supported")
        ) {
            guard method_getNumberOfArguments(supportedMethod) == 2,
                  methodReturnsObjectiveCBoolean(supportedMethod) else {
                return nil
            }
            let supportedSelector = NSSelectorFromString("supported")
            let supportedImplementation = unsafeBitCast(
                method_getImplementation(supportedMethod),
                to: SupportedImplementation.self
            )
            guard supportedImplementation(client, supportedSelector).boolValue else {
                return nil
            }
        }

        return NightShiftCoreBrightnessClient(
            client: client,
            statusSelector: statusSelector,
            setEnabledSelector: setEnabledSelector,
            statusImplementation: unsafeBitCast(
                method_getImplementation(statusMethod),
                to: GetStatusImplementation.self
            ),
            setEnabledImplementation: unsafeBitCast(
                method_getImplementation(setEnabledMethod),
                to: SetEnabledImplementation.self
            ),
            statusLayout: statusLayout
        )
    }

    func isEnabled() -> Bool? {
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: statusLayout.byteCount,
            alignment: statusLayout.alignment
        )
        defer { buffer.deallocate() }
        buffer.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: statusLayout.byteCount
        )

        guard statusImplementation(client, statusSelector, buffer).boolValue else {
            return nil
        }
        let enabled = buffer.load(
            fromByteOffset: statusLayout.enabledOffset,
            as: UInt8.self
        )
        guard enabled == 0 || enabled == 1 else {
            return nil
        }
        return enabled == 1
    }

    func setEnabled(_ enabled: Bool) -> Bool {
        setEnabledImplementation(
            client,
            setEnabledSelector,
            ObjCBool(enabled)
        ).boolValue
    }

    private static func methodReturnsObjectiveCBoolean(_ method: Method) -> Bool {
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        return NightShiftObjectiveCABI.isBoolean(returnType.pointee)
    }

    private static func methodArgumentIsObjectiveCBoolean(
        _ method: Method,
        index: UInt32
    ) -> Bool {
        guard let argumentType = method_copyArgumentType(method, index) else {
            return false
        }
        defer { free(argumentType) }
        return NightShiftObjectiveCABI.isBoolean(argumentType.pointee)
    }
}
