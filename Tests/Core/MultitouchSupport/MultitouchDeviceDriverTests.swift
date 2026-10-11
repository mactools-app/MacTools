import Foundation
import XCTest
import MacToolsPluginKit
import MultitouchSupport
@testable import MacTools

private final class InventoryTestRuntime: MultitouchRuntimeProviding {
    let entries: [MultitouchDeviceEntry]

    init(_ descriptors: [TrackpadSensorDevice]) {
        // Fake handles provide distinct pointer identities without calling native APIs.
        entries = descriptors.map {
            MultitouchDeviceEntry(device: unsafeBitCast(NSObject(), to: MTDevice.self), descriptor: $0)
        }
    }

    func createDeviceCollection() -> MultitouchDeviceCollection? { .init(entries: entries) }
    func register(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction,
                  refcon: UnsafeMutableRawPointer) {}
    func unregister(_ device: MTDevice, callback: MTFrameCallbackWithRefconFunction) {}
    func start(_ device: MTDevice) {}
    func stop(_ device: MTDevice) {}
}

@MainActor
final class MultitouchDeviceDriverTests: XCTestCase {
    func testInventoryPreservesCalibrationIdentityUnlessIDIsReplaced() {
        let stable = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn,
                                         supportsForce: true, hasPersistentIdentity: true)
        let temporary = TrackpadSensorDevice(deviceID: 2, isBuiltIn: false, transport: .usb)
        let missingID = TrackpadSensorDevice(deviceID: 0, isBuiltIn: true, transport: .builtIn,
                                            supportsForce: true, hasPersistentIdentity: true)
        let driver = MultitouchDeviceDriver(runtime: InventoryTestRuntime([stable, stable, temporary, missingID]))

        let devices = driver.availableDevices()

        XCTAssertEqual(devices.count, 4)
        XCTAssertEqual(devices[0], stable)
        XCTAssertEqual(devices[2], temporary)
        XCTAssertEqual(Set(devices.map(\.deviceID)).count, 4)
        XCTAssertFalse(devices.contains { $0.deviceID == 0 })
        XCTAssertFalse(devices[1].hasPersistentIdentity)
        XCTAssertFalse(devices[3].hasPersistentIdentity)
        XCTAssertTrue(devices[1].supportsWeighing)
        XCTAssertTrue(devices[3].supportsWeighing)
    }
}
