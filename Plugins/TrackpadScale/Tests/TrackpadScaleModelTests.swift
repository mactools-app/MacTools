import Foundation
import XCTest
import MacToolsPluginKit
@testable import TrackpadScalePlugin

@MainActor
private final class ScaleTestStorage: PluginStorage {
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func migrateValueIfNeeded(fromLegacyKey legacyKey: String, to key: String) {}
}

private final class ScaleTestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@MainActor @Sendable () -> Void] = []
    func enqueue(_ body: @escaping @MainActor @Sendable () -> Void) { lock.withLock { work.append(body) } }
    @MainActor func flush() {
        let pending = lock.withLock { let result = work; work.removeAll(); return result }
        pending.forEach { $0() }
    }
}

@MainActor
private final class ScaleTestService: TrackpadInputService {
    var devices = [TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn,
                                        supportsForce: true, hasPersistentIdentity: true)]
    var gesturesArePaused: Bool { !handlers.isEmpty }
    var handlers: [UUID: @Sendable (TrackpadSensorEvent) -> Void] = [:]
    func subscribe(purpose: TrackpadInputPurpose, handler: @escaping @Sendable (TrackpadSensorEvent) -> Void) -> UUID? {
        let id = UUID(); handlers[id] = handler; return id
    }
    func unsubscribe(_ subscriptionID: UUID) { handlers.removeValue(forKey: subscriptionID) }
    func send(_ frame: TrackpadSensorFrame) { handlers.values.forEach { $0(.frame(frame)) } }
    func interrupt() { handlers.values.forEach { $0(.interrupted) } }
}

@MainActor
final class TrackpadScaleModelTests: XCTestCase {
    private func frame(_ pressure: Double, time: Double, contactID: Int = 1, deviceID: UInt64 = 1) -> TrackpadSensorFrame {
        TrackpadSensorFrame(deviceID: deviceID, timestamp: time,
            contacts: [TrackpadSensorContact(identifier: contactID, x: 0.5, y: 0.5, pressure: pressure)])
    }
    private func settle(_ service: ScaleTestService, _ scheduler: ScaleTestScheduler, pressure: Double,
                        from start: Double, samples: Int = 15) {
        for index in 0..<samples {
            service.send(frame(pressure, time: start + Double(index) * 0.05))
            scheduler.flush()
        }
    }

    func testCalibrationPersistsByDeviceAndTareNeverPersists() throws {
        let storage = ScaleTestStorage()
        storage.values["calibration-factors.v1"] = ["1": Double.nan, "2": 4.0]
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let model = TrackpadScaleModel(storage: storage, schedule: { scheduler.enqueue($0) })
        model.setService(service)
        model.start()
        model.start()
        XCTAssertEqual(service.handlers.count, 1)
        XCTAssertEqual(model.measurement.state, .noContact)
        settle(service, scheduler, pressure: 10, from: 0)
        model.tare()
        // Each batch has an asymmetric spike, while its latest raw sample is 20.
        for index in 0..<15 {
            let time = 0.8 + Double(index) * 0.05
            service.send(frame(21, time: time))
            service.send(frame(20, time: time + 0.01))
            service.send(frame(20, time: time + 0.02))
            scheduler.flush()
        }
        model.calibrate("30junk")
        XCTAssertTrue(model.calibrationError)
        model.calibrate("30")
        XCTAssertFalse(model.calibrationError)
        XCTAssertTrue(model.hasCalibration)
        let factors = try XCTUnwrap(storage.values["calibration-factors.v1"] as? [String: Double])
        XCTAssertEqual(factors["1"] ?? -1, 3, accuracy: 0.01)
        XCTAssertEqual(factors["2"], 4)
        settle(service, scheduler, pressure: 20, from: 1.6)
        XCTAssertEqual(try XCTUnwrap(model.measurement.estimatedGrams), 30, accuracy: 0.01)
        model.stop()
        XCTAssertFalse(service.gesturesArePaused)
        model.start()
        XCTAssertEqual(model.measurement.factor, 3, accuracy: 0.01)
        XCTAssertNil(model.measurement.tare)
        XCTAssertNil(model.measurement.estimatedGrams)
        model.resetCalibration()
        XCTAssertFalse(model.hasCalibration)
        XCTAssertNil((storage.values["calibration-factors.v1"] as? [String: Double])?["1"])
        model.stop()
        service.devices = [TrackpadSensorDevice(deviceID: 2, isBuiltIn: true, transport: .builtIn,
                                               supportsForce: true, hasPersistentIdentity: true)]
        model.start()
        XCTAssertEqual(model.measurement.factor, 4)
        model.stop()
    }

    func testCoalescedContactBoundaryInvalidatesTareAndOldSessionCannotPublish() throws {
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let model = TrackpadScaleModel(storage: ScaleTestStorage(), schedule: { scheduler.enqueue($0) })
        model.setService(service)
        model.start()
        settle(service, scheduler, pressure: 10, from: 0)
        model.tare()
        settle(service, scheduler, pressure: 20, from: 0.8)
        service.send(TrackpadSensorFrame(deviceID: 1, timestamp: 1.6, contacts: []))
        service.send(frame(20, time: 1.65))
        scheduler.flush()
        XCTAssertNil(model.measurement.tare)
        XCTAssertNil(model.measurement.estimatedGrams)
        let staleHandler = try XCTUnwrap(service.handlers.values.first)
        service.interrupt()
        scheduler.flush()
        XCTAssertEqual(model.measurement.state, .interrupted)
        XCTAssertFalse(service.gesturesArePaused)
        model.start()
        staleHandler(.frame(frame(200, time: 2)))
        scheduler.flush()
        XCTAssertEqual(model.measurement.state, .noContact)
        XCTAssertNil(model.measurement.estimatedGrams)
        model.stop()
    }

    func testCalibrationAcceptsLocaleNumbersAndRejectsPartialInput() {
        for (locale, weight) in [(Locale(identifier: "de_DE"), "30,5"),
                                (Locale(identifier: "ar_EG@numbers=arab"), "٣٠٫٥")] {
            let scheduler = ScaleTestScheduler()
            let service = ScaleTestService()
            let model = TrackpadScaleModel(storage: ScaleTestStorage(), schedule: { scheduler.enqueue($0) })
            model.setService(service)
            model.start()
            settle(service, scheduler, pressure: 10, from: 0)
            model.tare()
            settle(service, scheduler, pressure: 20, from: 0.8)
            model.calibrate(weight + "junk", locale: locale)
            XCTAssertTrue(model.calibrationError)
            XCTAssertEqual(model.measurement.factor, 1)
            model.calibrate(weight, locale: locale)
            XCTAssertFalse(model.calibrationError)
            XCTAssertEqual(model.measurement.factor, 3.05, accuracy: 0.01)
            XCTAssertEqual(service.handlers.count, 1)
            model.stop()
        }
    }

    func testRestartAfterContactLossCapturesAFreshBaseline() throws {
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let model = TrackpadScaleModel(storage: ScaleTestStorage(), schedule: { scheduler.enqueue($0) })
        model.setService(service)
        model.start()
        settle(service, scheduler, pressure: 10, from: 0)
        settle(service, scheduler, pressure: 10, from: 0.75)
        XCTAssertNotNil(model.measurement.tare)
        service.send(TrackpadSensorFrame(deviceID: 1, timestamp: 1.5, contacts: []))
        scheduler.flush()
        XCTAssertNil(model.measurement.tare)
        XCTAssertFalse(model.measurement.isAutoTarePending)

        let staleHandler = try XCTUnwrap(service.handlers.values.first)
        model.restart()
        XCTAssertEqual(service.handlers.count, 1)
        XCTAssertTrue(model.measurement.isAutoTarePending)
        staleHandler(.interrupted)
        scheduler.flush()
        XCTAssertTrue(model.isRunning)
        settle(service, scheduler, pressure: 20, from: 2)
        settle(service, scheduler, pressure: 20, from: 2.75)
        XCTAssertEqual(try XCTUnwrap(model.measurement.tare), 20, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(model.measurement.estimatedGrams), 0, accuracy: 0.01)
        model.stop()
        XCTAssertFalse(service.gesturesArePaused)
    }

    func testCoalescingPreservesPressureSpikesAndInvalidSamples() {
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let model = TrackpadScaleModel(storage: ScaleTestStorage(), schedule: { scheduler.enqueue($0) })
        model.setService(service)
        model.start()
        settle(service, scheduler, pressure: 10, from: 0)
        model.tare()
        settle(service, scheduler, pressure: 20, from: 0.8)
        XCTAssertTrue(model.measurement.isStable)
        service.send(frame(60, time: 1.6))
        service.send(frame(20, time: 1.65))
        scheduler.flush()
        XCTAssertFalse(model.measurement.isStable)
        service.send(frame(.nan, time: 1.7))
        service.send(frame(20, time: 1.75))
        scheduler.flush()
        XCTAssertNil(model.measurement.tare)
        XCTAssertNil(model.measurement.estimatedGrams)
        model.stop()
    }

    func testAutoCaptureReleasesInputAndKeepsResultUntilNextStart() throws {
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let storage = ScaleTestStorage()
        let model = TrackpadScaleModel(storage: storage, schedule: { scheduler.enqueue($0) })
        model.setService(service)
        XCTAssertTrue(model.autoCaptureEnabled)
        model.start()
        settle(service, scheduler, pressure: 10, from: 0, samples: 25)
        settle(service, scheduler, pressure: 11, from: 1.25, samples: 60)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.capturedReading)

        let staleHandler = try XCTUnwrap(service.handlers.values.first)
        settle(service, scheduler, pressure: 20, from: 4.25, samples: 65)
        let captured = try XCTUnwrap(model.capturedReading)
        XCTAssertEqual(captured.grams, 10, accuracy: 0.1)
        XCTAssertFalse(captured.wasCalibrated)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(service.gesturesArePaused)
        XCTAssertNil(model.measurement.tare)
        XCTAssertNil(model.measurement.estimatedGrams)
        staleHandler(.frame(frame(100, time: 8)))
        staleHandler(.interrupted)
        scheduler.flush()
        model.stop(interrupted: true)
        XCTAssertEqual(model.capturedReading?.grams, captured.grams)
        XCTAssertTrue(storage.values.isEmpty)

        model.start()
        XCTAssertNil(model.capturedReading)
        XCTAssertTrue(model.measurement.isAutoTarePending)
        model.stop()
    }

    func testAutoCaptureOptOutPersistsAndCalibrationPausesCapture() throws {
        let scheduler = ScaleTestScheduler()
        let service = ScaleTestService()
        let storage = ScaleTestStorage()
        let model = TrackpadScaleModel(storage: storage, schedule: { scheduler.enqueue($0) })
        model.setAutoCaptureEnabled(false)
        XCTAssertFalse(TrackpadScaleModel(storage: storage).autoCaptureEnabled)
        model.setService(service)
        model.start()
        settle(service, scheduler, pressure: 10, from: 0, samples: 25)
        settle(service, scheduler, pressure: 20, from: 1.25, samples: 65)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.capturedReading)
        model.setAutoCaptureEnabled(true)
        settle(service, scheduler, pressure: 20, from: 4.5, samples: 20)
        model.setCalibrationExpanded(true)
        settle(service, scheduler, pressure: 20, from: 5.5, samples: 65)
        model.calibrate("30")
        XCTAssertFalse(model.calibrationError)
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.capturedReading)
        XCTAssertTrue(model.hasCalibration)

        model.setCalibrationExpanded(false)
        settle(service, scheduler, pressure: 20, from: 8.75, samples: 25)
        XCTAssertTrue(model.isRunning)
        settle(service, scheduler, pressure: 20, from: 10, samples: 35)
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(try XCTUnwrap(model.capturedReading).grams, 30, accuracy: 0.1)
        XCTAssertTrue(try XCTUnwrap(model.capturedReading).wasCalibrated)
    }
}
