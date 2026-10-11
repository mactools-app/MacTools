import Combine
import Foundation
import MacToolsPluginKit

/// One pending sample, plus a boundary flag, avoids an unbounded main-thread queue.
/// Contact transitions and invalid data cannot disappear when samples are coalesced.
final class TrackpadScaleMailbox: @unchecked Sendable {
    typealias Scheduler = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
    static let defaultScheduler: Scheduler = { work in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private let schedule: Scheduler
    private let lock = NSLock()
    private var pending: TrackpadSensorFrame?
    private var boundary = false
    private var interrupted = false
    private var scheduled = false
    private var signature: [Int]?
    private var lastInputTimestamp: TimeInterval?
    private var minimumPressure: Double?
    private var maximumPressure: Double?
    private var deviceID: UInt64?

    func selectDevice(_ id: UInt64?) { lock.withLock { deviceID = id } }
    private let deliver: @MainActor @Sendable (TrackpadSensorFrame?, Bool, Bool, ClosedRange<Double>?) -> Void

    init(schedule: @escaping Scheduler = defaultScheduler,
         deliver: @escaping @MainActor @Sendable (TrackpadSensorFrame?, Bool, Bool, ClosedRange<Double>?) -> Void) {
        self.schedule = schedule
        self.deliver = deliver
    }

    func receive(_ event: TrackpadSensorEvent) {
        let shouldSchedule = lock.withLock {
            switch event {
            case .interrupted:
                interrupted = true
                pending = nil
            case let .frame(frame):
                guard frame.deviceID == deviceID else { return false }
                let next = frame.contacts.map(\.identifier)
                if let signature, signature != next { boundary = true }
                signature = next
                if !frame.timestamp.isFinite
                    || lastInputTimestamp.map({ frame.timestamp <= $0 }) == true
                    || frame.contacts.contains(where: {
                    !$0.pressure.isFinite || $0.pressure <= 0 || !$0.x.isFinite || !$0.y.isFinite
                        || !(0...1).contains($0.x) || !(0...1).contains($0.y)
                }) { boundary = true }
                lastInputTimestamp = frame.timestamp
                if frame.contacts.count == 1, let pressure = frame.contacts.first?.pressure, pressure.isFinite {
                    minimumPressure = min(minimumPressure ?? pressure, pressure)
                    maximumPressure = max(maximumPressure ?? pressure, pressure)
                }
                pending = frame
            }
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        if shouldSchedule {
            schedule { [self] in
                let values = lock.withLock {
                    let range = minimumPressure.flatMap { lower in maximumPressure.map { lower...$0 } }
                    let values = (pending, boundary, interrupted, range)
                    pending = nil
                    boundary = false
                    interrupted = false
                    scheduled = false
                    minimumPressure = nil
                    maximumPressure = nil
                    return values
                }
                deliver(values.0, values.1, values.2, values.3)
            }
        }
    }
}

@MainActor
final class TrackpadScaleModel: ObservableObject {
    struct CapturedReading {
        let grams: Double
        let wasCalibrated: Bool
    }

    private enum StorageKey {
        static let autoCaptureEnabled = "auto-capture.enabled"
    }

    @Published private(set) var measurement = TrackpadScaleMeasurement()
    @Published private(set) var isRunning = false
    @Published private(set) var capturedReading: CapturedReading?
    @Published private(set) var autoCaptureEnabled: Bool
    @Published private(set) var isCalibrationExpanded = false
    @Published var calibrationError = false
    @Published private(set) var hasCalibration = false
    private var service: (any TrackpadInputService)?
    private var subscription: UUID?
    private var generation = UUID()
    private let storage: any PluginStorage
    private var watchdog: Timer?
    private var lastArrival: TimeInterval?
    private let schedule: TrackpadScaleMailbox.Scheduler
    private var calibrationFactors: [String: Double]

    init(storage: any PluginStorage, schedule: @escaping TrackpadScaleMailbox.Scheduler = TrackpadScaleMailbox.defaultScheduler) {
        self.storage = storage
        self.schedule = schedule
        autoCaptureEnabled = storage.object(forKey: StorageKey.autoCaptureEnabled) as? Bool ?? true
        calibrationFactors = (storage.object(forKey: "calibration-factors.v1") as? [String: Double] ?? [:])
            .filter { TrackpadScaleMeasurement.validFactor($0.value) }
    }

    isolated deinit {
        watchdog?.invalidate()
        if let subscription { service?.unsubscribe(subscription) }
    }

    func setService(_ service: any TrackpadInputService) {
        if let current = self.service, current !== service { stop(interrupted: true) }
        self.service = service
    }

    func start() {
        guard !isRunning else { return }
        capturedReading = nil
        guard let service else { measurement.start(device: nil, factor: 1); return }
        let currentGeneration = UUID()
        generation = currentGeneration
        let mailbox = TrackpadScaleMailbox(schedule: schedule) { [weak self] frame, boundary, interrupted, range in
            guard let self, self.isRunning, self.generation == currentGeneration else { return }
            if interrupted { self.stop(interrupted: true); return }
            if boundary { self.measurement.invalidate(.needsTare) }
            if let frame {
                self.lastArrival = ProcessInfo.processInfo.systemUptime
                self.measurement.receive(frame, pressureRange: range,
                                         autoCapture: self.autoCaptureEnabled && !self.isCalibrationExpanded)
                if self.measurement.captureProgress == 1, let grams = self.measurement.estimatedGrams {
                    self.capturedReading = CapturedReading(grams: grams, wasCalibrated: self.hasCalibration)
                    self.stop()
                }
            }
        }
        guard let token = service.subscribe(purpose: .weighing, handler: { mailbox.receive($0) }) else {
            if service.devices.contains(where: \.supportsWeighing) {
                measurement.stop(interrupted: true)
            } else { measurement.start(device: nil, factor: 1) }
            return
        }
        subscription = token
        let device = service.devices.first(where: \.supportsWeighing)
        mailbox.selectDevice(device?.deviceID)
        let factor = device.flatMap { $0.hasPersistentIdentity ? calibrationFactors[String($0.deviceID)] : nil } ?? 1
        measurement.start(device: device, factor: factor)
        hasCalibration = device.map { $0.hasPersistentIdentity && calibrationFactors[String($0.deviceID)] != nil } ?? false
        calibrationError = false
        isRunning = true
        lastArrival = ProcessInfo.processInfo.systemUptime
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.measurement.state != .noContact, let lastArrival = self.lastArrival,
                      ProcessInfo.processInfo.systemUptime - lastArrival > 2 else { return }
                self.stop(interrupted: true)
            }
        }
        watchdog?.tolerance = 0.2
    }

    func stop(interrupted: Bool = false) {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        lastArrival = nil
        if let subscription { service?.unsubscribe(subscription) }
        subscription = nil
        isRunning = false
        measurement.stop(interrupted: interrupted)
        calibrationError = false
        hasCalibration = false
    }

    func restart() {
        stop()
        start()
    }

    func setAutoCaptureEnabled(_ enabled: Bool) {
        guard enabled != autoCaptureEnabled else { return }
        autoCaptureEnabled = enabled
        storage.set(enabled, forKey: StorageKey.autoCaptureEnabled)
        measurement.resetCapture()
    }

    func setCalibrationExpanded(_ expanded: Bool) {
        guard expanded != isCalibrationExpanded else { return }
        isCalibrationExpanded = expanded
        measurement.resetCapture()
    }

    func tare() { calibrationError = false; _ = measurement.zero() }

    func calibrate(_ text: String, locale: Locale = PluginRuntimeLocalization.locale) {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        // Reject partial parsing (NumberFormatter can accept a valid prefix).
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = formatter.decimalSeparator ?? "."
        let characters = cleaned.replacingOccurrences(of: separator, with: ".")
        let normalized = characters.compactMap { character -> String? in
            if character == "." { return "." }
            guard character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }),
                  let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            return String(digit)
        }
        guard !normalized.isEmpty, normalized.count == characters.count,
              let value = Double(normalized.joined()), measurement.calibrate(knownGrams: value) else {
            calibrationError = true
            return
        }
        calibrationError = false
        hasCalibration = true
        persistCalibration()
    }

    func resetCalibration() {
        measurement.resetCalibration()
        calibrationError = false
        hasCalibration = false
        if let device = measurement.device, device.hasPersistentIdentity {
            calibrationFactors.removeValue(forKey: String(device.deviceID))
            storage.set(calibrationFactors, forKey: "calibration-factors.v1")
        }
    }

    private func persistCalibration() {
        guard let device = measurement.device, device.hasPersistentIdentity else { return }
        calibrationFactors[String(device.deviceID)] = measurement.factor
        storage.set(calibrationFactors, forKey: "calibration-factors.v1")
    }
}
