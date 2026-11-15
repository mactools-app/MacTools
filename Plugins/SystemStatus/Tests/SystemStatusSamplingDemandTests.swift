import XCTest
@testable import SystemStatusPlugin

@MainActor
final class SystemStatusSamplingDemandTests: XCTestCase {
    private func disabledConfiguration() -> SystemStatusConfiguration {
        var configuration = SystemStatusConfiguration.default
        configuration.panelItems = configuration.panelItems.map { .init(kind: $0.kind, isVisible: false) }
        return configuration
    }

    private func resolved(configuration: SystemStatusConfiguration, panelVisible: Bool,
                          detailKinds: Set<SystemStatusMetricKind> = []) -> SystemStatusSamplingDemand {
        SystemStatusSamplingPlan(background: .background(configuration: configuration),
            menuBar: .menuBar(configuration.menuBarItems),
            foreground: .foreground(configuration: configuration, panelVisible: panelVisible, detailKinds: detailKinds),
            schedule: .production).demand
    }

    func testDemandUnionsChartsMenuBarAndVisibleDetailsWithoutUnrelatedSensors() {
        var config = disabledConfiguration()
        XCTAssertTrue(resolved(configuration: config, panelVisible: false).isEmpty)
        config.menuBarItems = [.init(kind: .cpu, isVisible: true, values: [.temperature, .temperature])]
        XCTAssertEqual(resolved(configuration: config, panelVisible: false), .cpuTemperature)
        config.panelItems = [.init(kind: .memory, isVisible: true), .init(kind: .topProcesses, isVisible: true)]
        config.chartMetrics["memory"] = .pressure
        XCTAssertEqual(resolved(configuration: config, panelVisible: false), [.cpuTemperature, .memoryPressure])
        let visible = resolved(configuration: config, panelVisible: true)
        XCTAssertEqual(visible, [.cpuTemperature, .memoryPressure, .memoryUsage, .swap, .processes])
        let detail = resolved(configuration: config, panelVisible: false, detailKinds: [.cpu])
        XCTAssertTrue(detail.contains([.cpuUsage, .cpuPower, .cpuTemperature, .cpuLoad]))
        XCTAssertFalse(detail.contains(.processes))

        // Simplifying chart choices must not disable existing menu bar readings.
        config = disabledConfiguration()
        config.menuBarItems = [
            .init(kind: .cpu, isVisible: true, values: [.load]),
            .init(kind: .memory, isVisible: true, values: [.used, .swap]),
            .init(kind: .disk, isVisible: true, values: [.free, .read]),
            .init(kind: .network, isVisible: true, values: [.download, .upload]),
            .init(kind: .battery, isVisible: true, values: [.temperature])
        ]
        XCTAssertEqual(resolved(configuration: config, panelVisible: false),
            [.cpuLoad, .memoryUsage, .swap, .diskCapacity, .diskActivity, .network, .battery, .batteryDetails])
    }

    func testRefreshSkipsUnusedFamiliesAndStopsWithNoConsumers() async {
        let sampler = DemandSampler()
        let viewModel = SystemStatusViewModel(sampler: sampler, historyStore: DemandHistory())
        defer { viewModel.stop() }
        var config = disabledConfiguration()
        config.menuBarItems = [.init(kind: .cpu, isVisible: true, values: [.temperature])]
        viewModel.configure(config)
        await viewModel.refreshSnapshotNow()
        XCTAssertEqual(viewModel.snapshot.cpu.temperatureCelsius, 42)
        XCTAssertNil(viewModel.snapshot.cpu.usage)
        XCTAssertNil(viewModel.snapshot.cpu.cpuPowerWatts)
        let activeCounts = await sampler.counts
        XCTAssertEqual(activeCounts, [1, 0, 0])

        viewModel.configure(disabledConfiguration())
        await viewModel.refreshSnapshotNow()
        viewModel.startBackground()
        XCTAssertTrue(viewModel.activeDemand.isEmpty)
        let idleCounts = await sampler.counts
        XCTAssertEqual(idleCounts, activeCounts)
        XCTAssertNil(viewModel.snapshot.cpu.temperatureCelsius)
        XCTAssertTrue(viewModel.snapshot.topProcesses.isEmpty)
    }

    func testMenuBarCadenceDoesNotPromoteUnrelatedBackgroundSources() {
        var config = SystemStatusConfiguration.default
        config.menuBarItems = [.init(kind: .disk, isVisible: true, values: [.read, .write])]
        let plan = SystemStatusSamplingPlan(background: .background(configuration: config),
            menuBar: .menuBar(config.menuBarItems), foreground: [], schedule: .production)
        let initial = Dictionary(uniqueKeysWithValues: plan.intervals.keys.map { ($0, 0.0) })
        XCTAssertEqual(plan.due(at: 3, lastSamples: initial), .diskActivity)
        XCTAssertFalse(plan.due(at: 30, lastSamples: initial).needsSlow)
        XCTAssertTrue(plan.due(at: 300, lastSamples: initial).contains([.gpuUsage, .battery]))

        let temperatures = SystemStatusSamplingPlan(background: .cpuUsage, menuBar: .cpuTemperature,
            foreground: [], schedule: .production)
        XCTAssertEqual(temperatures.due(at: 3, lastSamples: [.cpuUsage: 0, .cpuTemperature: 0]), .cpuTemperature)
        XCTAssertEqual(temperatures.delay(at: 3, lastSamples: [.cpuUsage: 0, .cpuTemperature: 3]), 3)

        let promoted = SystemStatusSamplingPlan(background: .cpuUsage, menuBar: [],
            foreground: [.cpuUsage, .gpu], schedule: .production)
        XCTAssertFalse(promoted.due(at: 1, lastSamples: [.cpuUsage: 0, .gpuUsage: 0]).contains(.cpuUsage))
        XCTAssertTrue(promoted.due(at: 1, lastSamples: [.cpuUsage: 0, .gpuUsage: 0]).contains(.gpu))

        var snapshot = SystemStatusSnapshot.empty
        let cpuInterval = SystemStatusSampleInterval(endTimestamp: 30, duration: 30)
        snapshot.cpu = .init(usage: 0.5, loadAverage1Minute: nil, temperatureCelsius: 40, cpuPowerWatts: 8,
            isCollecting: false, usageInterval: cpuInterval)
        var sample = SystemStatusSnapshot.empty
        sample.cpu = .init(usage: nil, loadAverage1Minute: nil, temperatureCelsius: 42, cpuPowerWatts: nil, isCollecting: false)
        snapshot.merge(sample, demand: .cpuTemperature)
        XCTAssertEqual(snapshot.cpu.usage, 0.5)
        XCTAssertEqual(snapshot.cpu.cpuPowerWatts, 8)
        XCTAssertEqual(snapshot.cpu.temperatureCelsius, 42)
        XCTAssertEqual(snapshot.cpu.usageInterval, cpuInterval)
        XCTAssertNil(SystemStatusHistoryRates(snapshot: snapshot, sampled: .cpuTemperature).cpu)
        XCTAssertEqual(SystemStatusHistoryRates(snapshot: snapshot, sampled: .cpuUsage).cpu?.duration, 30)

        snapshot.memory = .init(usedBytes: 80, totalBytes: 100, swapUsedBytes: nil, swapTotalBytes: nil,
            pressure: .warning, pressurePercent: 30)
        snapshot.merge(sample, demand: .cpuTemperature)
        XCTAssertEqual(snapshot.memory.pressurePercent, 30)
        sample.memory.pressure = .normal
        sample.memory.pressurePercent = 20
        snapshot.merge(sample, demand: .memoryPressure)
        XCTAssertEqual(snapshot.memory.pressurePercent, 20)
        XCTAssertEqual(snapshot.memory.pressure, .normal)
        XCTAssertEqual(snapshot.memory.usage, 0.8)
        snapshot.removeUnrequestedValues(.memoryUsage)
        XCTAssertNil(snapshot.memory.pressurePercent)
        XCTAssertNil(snapshot.memory.pressure)
        XCTAssertEqual(snapshot.memory.usage, 0.8)
    }

    func testBatteryPowerStaysWithItsSampledPowerSource() {
        var snapshot = SystemStatusSnapshot.empty
        var sample = SystemStatusSnapshot.empty
        sample.battery = .init(isAvailable: true, level: 1, state: .charging,
            timeRemainingMinutes: 5, adapterWatts: nil, batteryPowerWatts: -40,
            temperatureCelsius: nil, healthPercent: nil, cycleCount: nil)
        snapshot.merge(sample, demand: [.battery, .batteryDetails])
        XCTAssertEqual(snapshot.battery.batteryPowerWatts, -40)

        sample.battery = .init(isAvailable: true, level: 1, state: .unplugged,
            timeRemainingMinutes: 120, adapterWatts: nil, batteryPowerWatts: nil,
            temperatureCelsius: nil, healthPercent: nil, cycleCount: nil)
        snapshot.merge(sample, demand: .battery)
        XCTAssertEqual(snapshot.battery.state, .unplugged)
        XCTAssertNil(snapshot.battery.batteryPowerWatts)

        sample.battery = .init(isAvailable: true, level: 1, state: .charging,
            timeRemainingMinutes: 5, adapterWatts: nil, batteryPowerWatts: -20,
            temperatureCelsius: nil, healthPercent: nil, cycleCount: nil)
        snapshot.merge(sample, demand: .batteryDetails)
        XCTAssertEqual(snapshot.battery.state, .charging)
        XCTAssertEqual(snapshot.battery.batteryPowerWatts, -20)
    }

    func testStoppedSamplingRejectsAnInFlightResult() async {
        let sampler = DemandSampler()
        let viewModel = SystemStatusViewModel(sampler: sampler, historyStore: DemandHistory())
        var config = disabledConfiguration()
        config.panelItems = [SystemStatusMetricKind.cpu, .battery, .topProcesses].map { .init(kind: $0, isVisible: true) }
        viewModel.configure(config)
        let entered = expectation(description: "Collector is in flight")
        await sampler.blockNextFast { entered.fulfill() }
        let refresh = Task { await viewModel.refreshSnapshotNow() }
        await fulfillment(of: [entered], timeout: 2)
        viewModel.stop()
        await sampler.resumeFast()
        await refresh.value
        XCTAssertTrue(viewModel.activeDemand.isEmpty)
        XCTAssertNil(viewModel.snapshot.cpu.usage)
        XCTAssertNil(viewModel.snapshot.cpu.temperatureCelsius)
        let counts = await sampler.counts
        XCTAssertEqual(counts, [1, 0, 0])
    }

    func testReopeningPanelRetainsSnapshotWithoutSamplingHiddenSourcesOrRecordingCachedHistory() async {
        let sampler = DemandSampler()
        let history = DemandHistory()
        let clock = SamplingClock()
        let viewModel = SystemStatusViewModel(sampler: sampler, historyStore: history, uptime: { clock.now })
        defer { viewModel.stop() }
        var config = disabledConfiguration()
        config.panelItems = [SystemStatusMetricKind.cpu, .disk, .topProcesses].map { .init(kind: $0, isVisible: true) }
        config.menuBarItems = [.init(kind: .cpu, isVisible: true, values: [.usage])]
        viewModel.configure(config)
        await viewModel.refreshSnapshotNow()
        XCTAssertEqual(viewModel.snapshot.cpu.cpuPowerWatts, 8)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertFalse(viewModel.snapshot.topProcesses.isEmpty)

        let background = expectation(description: "Background history recorded")
        await history.observeNextAppend { background.fulfill() }
        clock.now = 31
        viewModel.startBackground()
        await fulfillment(of: [background], timeout: 2)
        XCTAssertEqual(viewModel.activeDemand, [.cpuUsage, .diskActivity])
        XCTAssertEqual(viewModel.snapshot.cpu.cpuPowerWatts, 8)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertFalse(viewModel.snapshot.topProcesses.isEmpty)
        let counts = await sampler.counts
        XCTAssertEqual(counts, [2, 1, 1])
        let recorded = await history.lastPoint
        XCTAssertNotNil(recorded?.cpuUsage)
        XCTAssertNil(recorded?.cpuPowerWatts)
        XCTAssertNil(recorded?.cpuTemperatureCelsius)
        XCTAssertNil(recorded?.diskFreeBytes)

        clock.now = 3_600
        let refreshing = expectation(description: "Reopening starts a fresh collection")
        await sampler.blockNextFast { refreshing.fulfill() }
        viewModel.startForeground()
        XCTAssertEqual(viewModel.snapshot.cpu.cpuPowerWatts, 8)
        XCTAssertFalse(viewModel.snapshot.topProcesses.isEmpty)
        await fulfillment(of: [refreshing], timeout: 2)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        viewModel.returnToBackground()
        await sampler.resumeFast()

        // Hiding the CPU card leaves its menu bar usage on the same sampling plan.
        // Discard disabled secondary fields while retaining unrelated enabled cards.
        config.panelItems.removeAll { $0.kind == .cpu }
        viewModel.configure(config)
        XCTAssertEqual(viewModel.activeDemand, [.cpuUsage, .diskActivity])
        XCTAssertNil(viewModel.snapshot.cpu.cpuPowerWatts)
        XCTAssertNil(viewModel.snapshot.cpu.temperatureCelsius)
        XCTAssertEqual(viewModel.snapshot.cpu.usage, 0.5)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertFalse(viewModel.snapshot.topProcesses.isEmpty)
        viewModel.stop()
        XCTAssertNil(viewModel.snapshot.cpu.usage)
        XCTAssertNil(viewModel.snapshot.disk.totalBytes)
        XCTAssertTrue(viewModel.snapshot.topProcesses.isEmpty)
    }

    func testCompletedMetricsPublishBeforeSlowReadersAndProcessScanFinish() async {
        let sampler = DemandSampler()
        let viewModel = SystemStatusViewModel(sampler: sampler, historyStore: DemandHistory())
        defer { viewModel.stop() }
        let slow = expectation(description: "Slow collection is blocked")
        let processes = expectation(description: "Process collection is blocked")
        await sampler.blockNextSlow { slow.fulfill() }
        await sampler.blockNextProcess { processes.fulfill() }
        let refresh = Task { await viewModel.refreshSnapshotNow() }
        await fulfillment(of: [slow], timeout: 2)
        XCTAssertEqual(viewModel.snapshot.cpu.usage, 0.5)
        XCTAssertNil(viewModel.snapshot.disk.totalBytes)
        await sampler.resumeSlow()
        await fulfillment(of: [processes], timeout: 2)
        XCTAssertEqual(viewModel.snapshot.disk.totalBytes, 100)
        XCTAssertTrue(viewModel.snapshot.topProcesses.isEmpty)
        await sampler.resumeProcess()
        await refresh.value
        XCTAssertFalse(viewModel.snapshot.topProcesses.isEmpty)

        // A completed unavailable reading replaces the previous result.
        XCTAssertEqual(viewModel.snapshot.cpu.cpuPowerWatts, 8)
        await sampler.setCPUPower(nil)
        await viewModel.refreshSnapshotNow()
        XCTAssertNil(viewModel.snapshot.cpu.cpuPowerWatts)
    }
}

@MainActor
private final class SamplingClock {
    var now: TimeInterval = 1
}

private actor DemandSampler: SystemStatusSampling {
    var counts = [0, 0, 0]
    private var cpuPowerWatts: Double? = 8
    private var blocked: (@Sendable () -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedSlow: (@Sendable () -> Void)?
    private var slowContinuation: CheckedContinuation<Void, Never>?
    private var blockedProcess: (@Sendable () -> Void)?
    private var processContinuation: CheckedContinuation<Void, Never>?
    func setDemand(_ demand: SystemStatusSamplingDemand) {}
    func setCPUPower(_ watts: Double?) { cpuPowerWatts = watts }
    func blockNextFast(_ callback: @escaping @Sendable () -> Void) { blocked = callback }
    func resumeFast() { continuation?.resume(); continuation = nil }
    func blockNextSlow(_ callback: @escaping @Sendable () -> Void) { blockedSlow = callback }
    func resumeSlow() { slowContinuation?.resume(); slowContinuation = nil }
    func blockNextProcess(_ callback: @escaping @Sendable () -> Void) { blockedProcess = callback }
    func resumeProcess() { processContinuation?.resume(); processContinuation = nil }
    func collectFast(referenceDate: Date, demand: SystemStatusSamplingDemand) async -> SystemStatusFastSample {
        counts[0] += 1
        if let blocked {
            self.blocked = nil
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                blocked()
            }
        }
        return .init(cpu: .init(usage: 0.5, loadAverage1Minute: 2, temperatureCelsius: 42,
            cpuPowerWatts: cpuPowerWatts, isCollecting: false), memory: .empty, network: .empty, disk: .empty)
    }
    func collectSlow(demand: SystemStatusSamplingDemand) async -> SystemStatusSlowSample {
        counts[1] += 1
        if let blockedSlow {
            self.blockedSlow = nil
            await withCheckedContinuation { continuation in
                slowContinuation = continuation
                blockedSlow()
            }
        }
        return .init(disk: .init(usedBytes: 50, totalBytes: 100, readBytesPerSecond: nil, writeBytesPerSecond: nil),
            battery: .empty, gpu: .empty, hardware: .empty)
    }
    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess] {
        counts[2] += 1
        if let blockedProcess {
            self.blockedProcess = nil
            await withCheckedContinuation { continuation in
                processContinuation = continuation
                blockedProcess()
            }
        }
        return [.init(pid: 1, displayName: "Example", command: "/example", cpuPercent: 5, memoryBytes: 100)]
    }
    func collectPublicIPAddress() async -> String? { nil }
}

private actor DemandHistory: SystemStatusHistoryStoring {
    var lastPoint: SystemStatusHistoryPoint?
    private var onNextAppend: (@Sendable () -> Void)?
    func observeNextAppend(_ callback: @escaping @Sendable () -> Void) { onNextAppend = callback }
    func load(referenceDate: Date) async -> [SystemStatusHistoryPoint] { [] }
    func append(_ point: SystemStatusHistoryPoint, referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        await appendBatch([point], referenceDate: referenceDate)
    }
    func appendBatch(_ points: [SystemStatusHistoryPoint], referenceDate: Date) async -> [SystemStatusHistoryPoint] {
        lastPoint = points.last
        onNextAppend?()
        onNextAppend = nil
        return points
    }
}
