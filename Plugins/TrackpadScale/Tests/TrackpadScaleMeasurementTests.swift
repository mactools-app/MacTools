import Foundation
import XCTest
import MacToolsPluginKit
@testable import TrackpadScalePlugin

final class TrackpadScaleMeasurementTests: XCTestCase {
    private let device = TrackpadSensorDevice(deviceID: 1, isBuiltIn: true, transport: .builtIn,
                                              supportsForce: true, hasPersistentIdentity: true)
    private func frame(_ pressure: Double, time: Double, contactID: Int = 1, deviceID: UInt64 = 1) -> TrackpadSensorFrame {
        TrackpadSensorFrame(deviceID: deviceID, timestamp: time,
            contacts: [TrackpadSensorContact(identifier: contactID, x: 0.5, y: 0.5, pressure: pressure)])
    }
    private func settle(_ model: inout TrackpadScaleMeasurement, pressure: Double, from start: Double) {
        for index in 0..<25 { model.receive(frame(pressure, time: start + Double(index) * 0.05)) }
    }

    func testTareKnownWeightCalibrationAndFilterReset() {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        settle(&model, pressure: 10, from: 0)
        XCTAssertTrue(model.isStable)
        XCTAssertEqual(model.estimatedGrams ?? -1, 0, accuracy: 0.1)
        XCTAssertTrue(model.zero())
        XCTAssertFalse(model.isStable)
        settle(&model, pressure: 20, from: 1.3)
        XCTAssertEqual(model.estimatedGrams ?? -1, 10, accuracy: 0.1)
        XCTAssertTrue(model.calibrate(knownGrams: 30))
        XCTAssertEqual(model.factor, 3, accuracy: 0.01)
        XCTAssertFalse(model.isStable)
        XCTAssertNil(model.estimatedGrams)
        settle(&model, pressure: 20, from: 2.6)
        XCTAssertEqual(model.estimatedGrams ?? -1, 30, accuracy: 0.1)
        model.resetCalibration()
        XCTAssertEqual(model.factor, 1)
        XCTAssertNil(model.tare)
        XCTAssertNil(model.estimatedGrams)
    }

    func testSmoothingDoesNotMaskUnstableSamples() {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        settle(&model, pressure: 10, from: 0)
        XCTAssertTrue(model.zero())
        settle(&model, pressure: 20, from: 1.3)
        model.receive(frame(40, time: 2.55))
        XCTAssertFalse(model.isStable)
        XCTAssertGreaterThan(model.estimatedGrams ?? 0, 10)
        XCTAssertLessThan(model.estimatedGrams ?? 100, 30)
        XCTAssertFalse(model.calibrate(knownGrams: 10))
    }

    func testCalibrationAtFirstStableWindowDoesNotPersistDisplaySmoothing() {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        settle(&model, pressure: 10, from: 0)
        for index in 0..<12 {
            model.receive(frame(20, time: 1.3 + Double(index) * 0.05))
        }
        XCTAssertTrue(model.isStable)
        XCTAssertTrue(model.canCalibrate)
        XCTAssertTrue(model.calibrate(knownGrams: 30))
        model.receive(frame(20, time: 1.9))
        XCTAssertEqual(model.estimatedGrams ?? -1, 30, accuracy: 0.01)
        settle(&model, pressure: 20, from: 1.95)
        XCTAssertEqual(model.estimatedGrams ?? -1, 30, accuracy: 0.01)
    }

    func testAutomaticAndManualTareWorkWithFingerPressureVariation() throws {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        // A resting finger can vary by several native pressure units even
        // without an object. This must not block the initial baseline capture.
        for index in 0..<25 {
            model.receive(frame(index.isMultiple(of: 2) ? 10 : 14, time: Double(index) * 0.05),
                          pressureRange: 10...14)
            if index < 9 { XCTAssertFalse(model.canTare) }
        }
        XCTAssertFalse(model.isStable)
        XCTAssertNotNil(model.tare)
        XCTAssertFalse(model.isAutoTarePending)
        XCTAssertTrue(model.canTare)
        XCTAssertTrue(model.zero())
        let baseline = try XCTUnwrap(model.tare)
        XCTAssertGreaterThan(baseline, 10)
        XCTAssertLessThan(baseline, 14)
        XCTAssertFalse(model.canTare)
        settle(&model, pressure: baseline + 10, from: 1.3)
        XCTAssertEqual(model.estimatedGrams ?? -1, 10, accuracy: 0.1)
        model.receive(frame(40, time: 2.55), pressureRange: 20...40)
        XCTAssertFalse(model.isStable)
        XCTAssertFalse(model.canCalibrate)
        model.receive(TrackpadSensorFrame(deviceID: 1, timestamp: 2.6, contacts: []))
        XCTAssertFalse(model.canTare)
        XCTAssertNil(model.tare)
        model.receive(frame(14, time: 2.65, contactID: 2))
        XCTAssertFalse(model.canTare)
        XCTAssertNil(model.estimatedGrams)
    }

    func testAutomaticTareRunsOncePerStartAndPreservesObjectWeight() {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        XCTAssertTrue(model.isAutoTarePending)
        for index in 0..<15 { model.receive(frame(10, time: Double(index) * 0.05)) }
        XCTAssertNil(model.tare)
        XCTAssertNil(model.estimatedGrams)
        model.receive(TrackpadSensorFrame(deviceID: 1, timestamp: 0.75, contacts: []))
        XCTAssertTrue(model.isAutoTarePending)
        for index in 0..<15 { model.receive(frame(10, time: 0.8 + Double(index) * 0.05)) }
        XCTAssertNil(model.tare)
        for index in 15..<25 { model.receive(frame(10, time: 0.8 + Double(index) * 0.05)) }
        XCTAssertFalse(model.isAutoTarePending)
        XCTAssertEqual(model.state, .measuring)
        XCTAssertEqual(model.estimatedGrams ?? -1, 0, accuracy: 0.1)
        settle(&model, pressure: 20, from: 2.1)
        XCTAssertEqual(model.tare, 10)
        XCTAssertEqual(model.estimatedGrams ?? -1, 10, accuracy: 0.1)

        model.receive(TrackpadSensorFrame(deviceID: 1, timestamp: 3.35, contacts: []))
        XCTAssertNil(model.tare)
        settle(&model, pressure: 20, from: 3.4)
        XCTAssertEqual(model.state, .needsTare)
        XCTAssertNil(model.estimatedGrams)
        XCTAssertFalse(model.isAutoTarePending)
        XCTAssertTrue(model.zero())

        model.stop()
        model.start(device: device, factor: 1)
        XCTAssertTrue(model.isAutoTarePending)
        settle(&model, pressure: 10, from: 5)
        XCTAssertEqual(model.estimatedGrams ?? -1, 0, accuracy: 0.1)
    }

    func testInvalidInputsAndContactBoundariesAlwaysClearTareAndWeight() {
        let cases: [(String, TrackpadSensorFrame, TrackpadScaleMeasurement.State)] = [
            ("lift", TrackpadSensorFrame(deviceID: 1, timestamp: 2, contacts: []), .noContact),
            ("replacement", frame(20, time: 2, contactID: 2), .needsTare),
            ("device", frame(20, time: 2, deviceID: 2), .interrupted),
            ("nonfinite pressure", frame(.nan, time: 2), .invalidSample),
            ("negative pressure", frame(-1, time: 2), .invalidSample),
            ("zero pressure", frame(0, time: 2), .invalidSample),
            ("nonfinite time", frame(20, time: .infinity), .invalidSample),
            ("stale time", frame(20, time: 0), .invalidSample),
            ("multiple contacts", TrackpadSensorFrame(deviceID: 1, timestamp: 2,
                contacts: [frame(20, time: 2).contacts[0], frame(20, time: 2, contactID: 2).contacts[0]]), .multipleContacts)
        ]
        for (name, sample, state) in cases {
            var model = TrackpadScaleMeasurement()
            model.start(device: device, factor: 1)
            settle(&model, pressure: 10, from: 0)
            XCTAssertTrue(model.zero())
            model.receive(frame(20, time: 1.3))
            model.receive(sample)
            XCTAssertEqual(model.state, state, name)
            XCTAssertNil(model.tare, name)
            XCTAssertNil(model.estimatedGrams, name)
            XCTAssertFalse(model.canTare, name)
        }
    }

    func testRepeatedTareInterruptedSessionsAndCalibrationValidation() {
        var model = TrackpadScaleMeasurement()
        for _ in 0..<3 {
            model.start(device: device, factor: .nan)
            XCTAssertEqual(model.factor, 1)
            XCTAssertFalse(model.zero())
            settle(&model, pressure: 10, from: 0)
            XCTAssertTrue(model.zero())
            settle(&model, pressure: 20, from: 1.3)
            for invalid in [Double.nan, .infinity, 0, -1, 101] { XCTAssertFalse(model.calibrate(knownGrams: invalid)) }
            XCTAssertTrue(model.zero())
            settle(&model, pressure: 20, from: 2.6)
            XCTAssertEqual(model.estimatedGrams ?? -1, 0, accuracy: 0.1)
            model.receive(frame(30, time: 5))
            XCTAssertNil(model.tare)
            XCTAssertNil(model.estimatedGrams)
            model.stop(interrupted: true)
            XCTAssertEqual(model.state, .interrupted)
            XCTAssertNil(model.device)
        }
        let external = TrackpadSensorDevice(deviceID: 2, isBuiltIn: false, transport: .bluetooth, supportsForce: true)
        model.start(device: external, factor: 1)
        XCTAssertEqual(model.state, .unsupported)
    }

    func testAutoCaptureRejectsBaselineNoiseDriftAndCoalescedSpikes() throws {
        var model = TrackpadScaleMeasurement()
        model.start(device: device, factor: 1)
        for index in 0..<25 {
            model.receive(frame(index.isMultiple(of: 2) ? 10 : 14, time: Double(index) * 0.05),
                          pressureRange: 10...14, autoCapture: true)
        }
        let baseline = try XCTUnwrap(model.tare)
        // A steady change within the observed baseline variation is insufficient.
        for index in 0..<65 {
            model.receive(frame(baseline + 4, time: 1.25 + Double(index) * 0.05), autoCapture: true)
        }
        XCTAssertEqual(model.captureProgress, 0)
        // Slow drift can look stable in each short window but must not capture.
        for index in 0..<80 {
            model.receive(frame(baseline + 10 + Double(index) * 0.05,
                                time: 4.5 + Double(index) * 0.05), autoCapture: true)
            XCTAssertLessThan(model.captureProgress, 1)
        }
        for index in 0..<30 {
            model.receive(frame(baseline + 14, time: 8.5 + Double(index) * 0.05), autoCapture: true)
        }
        XCTAssertGreaterThan(model.captureProgress, 0)
        model.receive(frame(baseline + 14, time: 10), pressureRange: (baseline + 14)...(baseline + 40),
                      autoCapture: true)
        XCTAssertEqual(model.captureProgress, 0)
        for index in 0..<70 {
            model.receive(frame(baseline + 14, time: 10.05 + Double(index) * 0.05), autoCapture: true)
        }
        XCTAssertEqual(model.captureProgress, 1)
        XCTAssertTrue(model.zero())
        XCTAssertEqual(model.captureProgress, 0)
    }
}
