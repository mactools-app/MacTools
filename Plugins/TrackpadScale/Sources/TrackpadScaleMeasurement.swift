import Foundation
import MacToolsPluginKit

/// Empirical pressure units, never an Apple-specified mass or accuracy contract.
/// Only a small transient stability window is retained, and it is cleared at boundaries.
struct TrackpadScaleMeasurement {
    enum State: String {
        case stopped, unsupported, noContact, multipleContacts, needsTare, measuring, invalidSample, interrupted
    }

    private(set) var state: State = .stopped
    private(set) var device: TrackpadSensorDevice?
    private(set) var factor: Double = 1
    private(set) var estimatedGrams: Double?
    private(set) var isStable = false
    private(set) var hasPressureReading = false
    private(set) var tare: Double?
    private(set) var isAutoTarePending = false
    private(set) var captureProgress: Double = 0
    private var baselineNoise: Double = 0
    private var captureStartedAt: TimeInterval?
    private var capturePressureRange: ClosedRange<Double>?
    private var contactID: Int?
    private var contactStartedAt: TimeInterval?
    private var filtered: Double?
    private var lastTimestamp: TimeInterval?
    private var history: [(timestamp: TimeInterval, pressure: Double, range: ClosedRange<Double>)] = []

    // Tare captures a manual baseline. The quality badge must not make this
    // action depend on catching a brief low-variation window between updates.
    var canTare: Bool { hasFullWindow && filtered != nil && contactID != nil }
    var canCalibrate: Bool {
        guard isStable, let calibrationPressure, let tare else { return false }
        return calibrationPressure - tare > 0.5
    }

    private var calibrationPressure: Double? {
        guard !history.isEmpty else { return nil }
        let count = Double(history.count)
        // Use the raw samples driving the display, without its smoothing lag.
        // Coalesced extrema detect instability but are not representative samples.
        let pressure = history.reduce(0) { $0 + $1.pressure / count }
        return pressure.isFinite ? pressure : nil
    }

    private var pressureSpread: Double {
        (history.map { $0.range.upperBound }.max() ?? 0)
            - (history.map { $0.range.lowerBound }.min() ?? 0)
    }

    private var hasFullWindow: Bool {
        guard let firstTimestamp = history.first?.timestamp, let lastTimestamp else { return false }
        return history.count >= 6 && lastTimestamp - firstTimestamp >= 0.45
    }

    mutating func start(device: TrackpadSensorDevice?, factor: Double) {
        self = Self()
        guard let device, device.supportsWeighing else { state = .unsupported; return }
        self.device = device
        self.factor = Self.validFactor(factor) ? factor : 1
        isAutoTarePending = true
        state = .noContact
    }

    mutating func stop(interrupted: Bool = false) {
        self = Self()
        state = interrupted ? .interrupted : .stopped
    }

    mutating func invalidate(_ state: State) {
        tare = nil
        baselineNoise = 0
        contactID = nil
        resetFilter()
        self.state = state
    }

    mutating func receive(_ frame: TrackpadSensorFrame, pressureRange: ClosedRange<Double>? = nil,
                          autoCapture: Bool = false) {
        guard let device, state != .stopped, state != .unsupported else { return }
        guard frame.deviceID == device.deviceID else { invalidate(.interrupted); return }
        guard frame.timestamp.isFinite,
              lastTimestamp.map({ frame.timestamp > $0 }) ?? true else {
            invalidate(.invalidSample)
            return
        }
        if let lastTimestamp, frame.timestamp - lastTimestamp > 0.8 {
            invalidate(.interrupted)
        }
        guard !frame.contacts.isEmpty else { invalidate(.noContact); return }
        guard frame.contacts.count == 1 else { invalidate(.multipleContacts); return }
        let contact = frame.contacts[0]
        guard contact.pressure.isFinite, contact.pressure > 0,
              contact.x.isFinite, contact.y.isFinite,
              (0...1).contains(contact.x), (0...1).contains(contact.y) else {
            invalidate(.invalidSample)
            return
        }
        if contactID != contact.identifier {
            invalidate(.needsTare)
            contactID = contact.identifier
        }
        contactStartedAt = contactStartedAt ?? frame.timestamp
        hasPressureReading = true
        let elapsed = frame.timestamp - (lastTimestamp ?? frame.timestamp)
        let alpha = 1 - exp(-max(0, elapsed) / 0.20)
        filtered = filtered.map { $0 + alpha * (contact.pressure - $0) } ?? contact.pressure
        lastTimestamp = frame.timestamp
        // Time-based stability uses unsmoothed values so smoothing cannot hide motion.
        history.append((frame.timestamp, contact.pressure, pressureRange ?? contact.pressure...contact.pressure))
        history.removeAll { frame.timestamp - $0.timestamp > 0.6 }
        if history.count > 80 { history.removeFirst(history.count - 80) }
        let spread = pressureSpread
        isStable = hasFullWindow && spread * factor <= 1.5
        // Capture the initial baseline once per explicit Start. Later pressure
        // changes or returning fingers must not silently zero an object.
        if isAutoTarePending, canTare,
           frame.timestamp - (contactStartedAt ?? frame.timestamp) >= 1 {
            tare = filtered
            baselineNoise = spread
            isAutoTarePending = false
        }
        if let tare, let filtered {
            let grams = (filtered - tare) * factor
            guard grams.isFinite else { invalidate(.invalidSample); return }
            estimatedGrams = max(0, grams)
            state = .measuring
            updateCapture(timestamp: frame.timestamp, grams: grams,
                          pressureRange: pressureRange ?? contact.pressure...contact.pressure,
                          enabled: autoCapture)
        } else {
            estimatedGrams = nil
            state = .needsTare
            resetCapture()
        }
    }

    mutating func resetCapture() {
        captureStartedAt = nil
        capturePressureRange = nil
        captureProgress = 0
    }

    private mutating func updateCapture(timestamp: TimeInterval, grams: Double,
                                       pressureRange: ClosedRange<Double>, enabled: Bool) {
        // A positive change must exceed both the provisional two-gram floor
        // and twice the pressure variation observed when capturing the baseline.
        guard enabled, isStable, grams >= max(2, baselineNoise * factor * 2) else {
            resetCapture()
            return
        }
        let lower = min(capturePressureRange?.lowerBound ?? pressureRange.lowerBound, pressureRange.lowerBound)
        let upper = max(capturePressureRange?.upperBound ?? pressureRange.upperBound, pressureRange.upperBound)
        // Check the entire capture interval so slow drift cannot pass a series
        // of individually stable short windows. Coalesced spikes remain visible.
        if (upper - lower) * factor > 1.5 { resetCapture() }
        captureStartedAt = captureStartedAt ?? timestamp
        capturePressureRange = capturePressureRange.map { _ in lower...upper } ?? pressureRange
        captureProgress = min(1, max(0, (timestamp - (captureStartedAt ?? timestamp)) / 2))
    }

    @discardableResult
    mutating func zero() -> Bool {
        guard canTare, let filtered else { return false }
        tare = filtered
        baselineNoise = pressureSpread
        isAutoTarePending = false
        resetFilter()
        state = .measuring
        return true
    }

    /// Calibrate with an independently known small mass while the same finger stays in place.
    @discardableResult
    mutating func calibrate(knownGrams: Double) -> Bool {
        guard knownGrams.isFinite, (1...100).contains(knownGrams), canCalibrate,
              let calibrationPressure, let tare else { return false }
        let newFactor = knownGrams / (calibrationPressure - tare)
        guard Self.validFactor(newFactor) else { return false }
        factor = newFactor
        resetFilter()
        state = .measuring
        return true
    }

    mutating func resetCalibration() {
        factor = 1
        invalidate(.needsTare)
    }

    private mutating func resetFilter() {
        resetCapture()
        contactStartedAt = nil
        filtered = nil
        lastTimestamp = nil
        history.removeAll(keepingCapacity: true)
        estimatedGrams = nil
        isStable = false
        hasPressureReading = false
    }

    static func validFactor(_ factor: Double) -> Bool {
        factor.isFinite && (0.01...100).contains(factor)
    }
}
