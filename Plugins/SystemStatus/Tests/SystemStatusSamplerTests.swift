import XCTest
import IOKit.ps
@testable import MacTools
@testable import SystemStatusPlugin

final class SystemStatusSamplerTests: XCTestCase {
    func testCommandRunnerDrainsOutputLargerThanPipeBuffer() async throws {
        let lineCount = 100_000
        let commandResult = await SystemStatusCommandRunner.run(
            path: "/usr/bin/jot",
            arguments: ["-b", "x", String(lineCount)],
            timeout: 2
        )
        let result = try XCTUnwrap(commandResult)

        XCTAssertEqual(result.completion, .completed)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, String(repeating: "x\n", count: lineCount))
        XCTAssertEqual(result.standardError, "")
    }

    func testCommandRunnerTerminatesTimedOutProcess() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let commandResult = await SystemStatusCommandRunner.run(
            path: "/bin/sleep",
            arguments: ["5"],
            timeout: 0.05
        )
        let result = try XCTUnwrap(commandResult)

        XCTAssertEqual(result.completion, .timedOut)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }

    func testCommandRunnerHonorsCancellation() async {
        let task = Task {
            await SystemStatusCommandRunner.run(path: "/bin/sleep", arguments: ["5"], timeout: 10)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    func testBatteryTemperatureUsesNestedAndVirtualRegistryFallbacks() throws {
        XCTAssertEqual(
            try XCTUnwrap(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [nil, 3_589, 3_200])),
            35.89,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [12_000, 3_200])),
            32,
            accuracy: 0.001
        )
        XCTAssertNil(SystemStatusSampler.batteryTemperatureCelsius(rawValues: [nil, 12_000]))
    }

    func testCPUUsageCalculatorUsesPositiveTickDeltas() throws {
        let sample = try XCTUnwrap(SystemStatusCPUUsageCalculator.sample(
            current: SystemStatusCPUTicks(user: 150, system: 75, idle: 925, nice: 0),
            previous: SystemStatusCPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        ))

        XCTAssertEqual(sample.usage, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sample.totalTicks, 150)
    }

    func testPowerCalculatorUsesEnergyDeltaOverElapsedTime() throws {
        let previous = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(channels: ["CPU Energy": 100], uptime: 1_000))
        let current = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(channels: ["CPU Energy": 105], uptime: 1_002))
        let watts = try XCTUnwrap(SystemStatusPowerCalculator.watts(
            current: current, previous: previous
        ))

        XCTAssertEqual(watts, 2.5, accuracy: 0.0001)
        let zero = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(channels: ["CPU Energy": 100], uptime: 1_002))
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: zero, previous: previous), 0)
    }

    func testNetworkRateCalculatorDifferentiatesCountersByElapsedTime() {
        let rate = SystemStatusNetworkRateCalculator.rate(
            current: SystemStatusNetworkCounter(
                key: "iflist2:en0",
                displayName: "en0",
                receivedBytes: 16_000,
                sentBytes: 27_500,
                ipAddress: "192.168.1.2",
                isUp: true
            ),
            previous: SystemStatusNetworkCounter(
                key: "iflist2:en0",
                displayName: "en0",
                receivedBytes: 10_000,
                sentBytes: 20_000,
                ipAddress: "192.168.1.2",
                isUp: true
            ),
            elapsedSeconds: 3
        )

        XCTAssertEqual(rate?.downloadBytesPerSecond, 2_000)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 2_500)
    }

    func testDiskIORateCalculatorDifferentiatesCountersByElapsedTime() {
        let rate = SystemStatusDiskIORateCalculator.rate(
            current: SystemStatusDiskIOCounter(devices: [1: .init(readBytes: 16_000, writeBytes: 27_500)]),
            previous: SystemStatusDiskIOCounter(devices: [1: .init(readBytes: 10_000, writeBytes: 20_000)]),
            elapsedSeconds: 3
        )

        XCTAssertEqual(rate?.readBytesPerSecond, 2_000)
        XCTAssertEqual(rate?.writeBytesPerSecond, 2_500)
    }

    func testGPUUtilizationPrefersDeviceUtilizationOverPipelineCounters() throws {
        let usage = try XCTUnwrap(SystemStatusSampler.gpuUtilization(from: [
            "Device Utilization %": 18,
            "Renderer Utilization %": 100,
            "Tiler Utilization %": 100
        ]))

        XCTAssertEqual(usage, 0.18, accuracy: 0.0001)
    }

    func testGPUUtilizationFallsBackToGPUActivity() throws {
        let usage = try XCTUnwrap(SystemStatusSampler.gpuUtilization(from: [
            "GPU Activity(%)": 42,
            "Renderer Utilization %": 100,
            "Tiler Utilization %": 100
        ]))

        XCTAssertEqual(usage, 0.42, accuracy: 0.0001)
    }

    func testBatteryHealthPercentPrefersNominalChargeCapacity() {
        let health = SystemStatusSampler.batteryHealthPercent(
            designCapacity: 10_000,
            nominalChargeCapacity: 8_300,
            appleRawMaxCapacity: 7_800
        )

        XCTAssertEqual(health, 83)
    }

    func testBatteryPowerNormalizerUsesSignedBatteryPowerMilliwatts() throws {
        let encodedDischarge = NSNumber(value: UInt64(bitPattern: -40_000))
        let dischargingWatts = try XCTUnwrap(
            SystemStatusBatteryPowerNormalizer.telemetryWatts(fromRawMilliwatts: encodedDischarge)
        )
        let chargingWatts = try XCTUnwrap(
            SystemStatusBatteryPowerNormalizer.telemetryWatts(fromRawMilliwatts: 12_345)
        )

        XCTAssertEqual(dischargingWatts, 40, accuracy: 0.001)
        XCTAssertEqual(chargingWatts, -12.345, accuracy: 0.001)
    }

    func testUnpluggedBatteryFallsBackFromStaleChargingTelemetry() {
        var registry: [String: Any] = [
            "PowerTelemetryData": ["BatteryPower": 40_000],
            "BatteryPower": 40_000,
            "Voltage": 12_000,
            "InstantAmperage": UInt64(bitPattern: -1_000),
        ]
        XCTAssertEqual(SystemStatusSampler.batteryPowerWatts(state: .unplugged) { registry[$0] }, 12)

        registry["InstantAmperage"] = 1_000
        XCTAssertNil(SystemStatusSampler.batteryPowerWatts(state: .unplugged) { registry[$0] })
        XCTAssertEqual(SystemStatusSampler.batteryPowerWatts(state: .charging) { registry[$0] }, -40)
    }

    func testChargingBatteryFallsBackFromStaleDischargeTelemetry() {
        var registry: [String: Any] = [
            "PowerTelemetryData": ["BatteryPower": -40_000],
            "BatteryPower": -40_000,
            "Voltage": 12_000,
            "InstantAmperage": 1_000,
        ]
        XCTAssertEqual(SystemStatusSampler.batteryPowerWatts(state: .charging) { registry[$0] }, -12)

        registry["InstantAmperage"] = -1_000
        XCTAssertNil(SystemStatusSampler.batteryPowerWatts(state: .charging) { registry[$0] })
        XCTAssertEqual(SystemStatusSampler.batteryPowerWatts(state: .acPower) { registry[$0] }, 40)
    }

    func testCPUUsagePreservesTickWraparound() throws {
        let usage = try XCTUnwrap(SystemStatusCPUUsageCalculator.usage(
            current: .init(user: 10, system: 40, idle: 160, nice: 0),
            previous: .init(user: UInt32.max - 9, system: 20, idle: 100, nice: 0)
        ))
        XCTAssertEqual(usage, 0.4, accuracy: 0.0001)
    }

    func testTemperatureOnlyGPUReadingPreservesNativeAndFallbackSources() {
        let native = SystemStatusGPUSnapshot(usage: 0.2, name: "GPU", temperatureCelsius: 42, isAvailable: true, isCollecting: false)
        let temperature = SystemStatusSampler.gpuSample(demand: .gpuTemperature, registryReadings: { [native] }) {
            XCTFail("A readable native temperature does not need a fallback sensor")
            return nil
        }
        XCTAssertEqual(temperature.temperatureCelsius, 42)
        XCTAssertNil(temperature.usage)
        let fallback = SystemStatusSampler.gpuSample(demand: .gpuTemperature, registryReadings: { [] }) { 39 }
        XCTAssertEqual(fallback.temperatureCelsius, 39)
        XCTAssertTrue(fallback.isAvailable)
        let unavailable = SystemStatusSampler.gpuSample(demand: .gpuTemperature, registryReadings: { [] }) { nil }
        XCTAssertNil(unavailable.temperatureCelsius)
    }

    func testGPUPercentageUnitsAndUnavailableReadingsStayDistinct() throws {
        for value: Any in [0.5, "0.5", NSNumber(value: 0.5)] {
            XCTAssertEqual(try XCTUnwrap(SystemStatusSampler.gpuUtilization(from: ["Device Utilization %": value])), 0.005)
        }
        XCTAssertNil(SystemStatusSampler.gpuUtilization(from: ["GPU Activity(%)": -1]))
        let unknown = SystemStatusSampler.gpuSnapshot(readings: [], fallbackTemperature: 45)
        XCTAssertTrue(unknown.isAvailable)
        XCTAssertNil(unknown.usage)
        let selected = SystemStatusSampler.gpuSnapshot(readings: [
            .init(usage: 0.1, name: "Integrated", temperatureCelsius: 40, isAvailable: true, isCollecting: false),
            .init(usage: 0.8, name: "Discrete", temperatureCelsius: 60, isAvailable: true, isCollecting: false)
        ], fallbackTemperature: 45)
        XCTAssertEqual(selected.name, "Discrete")
        XCTAssertEqual(selected.usage, 0.8)
        XCTAssertEqual(selected.temperatureCelsius, 60)
    }

    func testRatesPreserveFastTransfersAndRejectResetOrChangedCounters() throws {
        let old = SystemStatusNetworkCounter(key: "en0", displayName: "Wi-Fi", receivedBytes: 0, sentBytes: 10, ipAddress: nil, isUp: true)
        let fast = SystemStatusNetworkCounter(key: "en0", displayName: "Wi-Fi", receivedBytes: 15_000_000_000, sentBytes: 10, ipAddress: nil, isUp: true)
        XCTAssertEqual(SystemStatusNetworkRateCalculator.rate(current: fast, previous: old, elapsedSeconds: 3)?.downloadBytesPerSecond, 5_000_000_000)
        XCTAssertNil(SystemStatusNetworkRateCalculator.rate(current: old, previous: fast, elapsedSeconds: 3))
        XCTAssertNil(SystemStatusNetworkRateCalculator.rate(current: fast, previous: old, elapsedSeconds: .nan))
        XCTAssertNil(SystemStatusNetworkRateCalculator.rate(current: fast, previous: old, elapsedSeconds: .infinity))

        let previous = SystemStatusDiskIOCounter(devices: [1: .init(readBytes: 0, writeBytes: 100)])
        let current = SystemStatusDiskIOCounter(devices: [1: .init(readBytes: 36_000_000_000, writeBytes: 100)])
        XCTAssertEqual(SystemStatusDiskIORateCalculator.rate(current: current, previous: previous, elapsedSeconds: 3)?.readBytesPerSecond, 12_000_000_000)
        let replacement = SystemStatusDiskIOCounter(devices: [2: .init(readBytes: 36_000_000_000, writeBytes: 100)])
        XCTAssertNil(SystemStatusDiskIORateCalculator.rate(current: replacement, previous: previous, elapsedSeconds: 3))
        XCTAssertNil(SystemStatusDiskIORateCalculator.rate(current: previous, previous: current, elapsedSeconds: 3))
    }

    func testNetworkAggregationIncludesEveryActivePhysicalInterfaceWithoutVPNDuplicates() {
        let wifi = SystemStatusNetworkCounter(key: "iflist2:1:en0", displayName: "Wi-Fi", receivedBytes: 100, sentBytes: 200, ipAddress: "192.0.2.1", isUp: true)
        let vpn = SystemStatusNetworkCounter(key: "iflist2:2:utun0", displayName: "VPN", receivedBytes: 1_000, sentBytes: 2_000, ipAddress: "192.0.2.2", isUp: true)
        let ethernet = SystemStatusNetworkCounter(key: "iflist2:3:en1", displayName: "Ethernet", receivedBytes: 10_000, sentBytes: 20_000, ipAddress: nil, isUp: true)
        let down = SystemStatusNetworkCounter(key: "iflist2:4:en2", displayName: "Ethernet", receivedBytes: 50, sentBytes: 50, ipAddress: nil, isUp: false)
        let counters = SystemStatusSampler.activeNetworkCounters(["en0": wifi, "utun0": vpn, "en1": ethernet, "en2": down])
        XCTAssertEqual(counters, ["en0": wifi, "en1": ethernet])
        let changedWifi = SystemStatusNetworkCounter(key: wifi.key, displayName: "Wi-Fi", receivedBytes: 160, sentBytes: 230, ipAddress: nil, isUp: true)
        let changedEthernet = SystemStatusNetworkCounter(key: ethernet.key, displayName: "Ethernet", receivedBytes: 10_400, sentBytes: 20_030, ipAddress: nil, isUp: true)
        let rate = SystemStatusNetworkRateCalculator.rate(
            current: ["en0": changedWifi, "en1": changedEthernet], previous: counters, elapsedSeconds: 2
        )
        XCTAssertEqual(rate?.downloadBytesPerSecond, 230)
        XCTAssertEqual(rate?.uploadBytesPerSecond, 30)
        let resetWifi = SystemStatusNetworkCounter(key: wifi.key, displayName: "Wi-Fi", receivedBytes: 0, sentBytes: 0, ipAddress: nil, isUp: true)
        XCTAssertNil(SystemStatusNetworkRateCalculator.rate(
            current: ["en0": resetWifi, "en1": changedEthernet], previous: counters, elapsedSeconds: 2
        ))
        XCTAssertNil(SystemStatusNetworkRateCalculator.rate(current: ["en0": changedWifi], previous: counters, elapsedSeconds: 2))
    }

    func testNetworkMessageScanContinuesPastShortAddressRecords() throws {
        var address = ifa_msghdr()
        address.ifam_msglen = UInt16(MemoryLayout<ifa_msghdr>.size)
        address.ifam_type = UInt8(RTM_NEWADDR)
        var interface = if_msghdr2()
        interface.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        interface.ifm_type = UInt8(RTM_IFINFO2)
        interface.ifm_index = 7
        interface.ifm_data.ifi_ibytes = 10_000_000_000
        var bytes = withUnsafeBytes(of: address) { Array($0) }
        bytes += withUnsafeBytes(of: interface) { Array($0) }
        // An incomplete trailing message must not read beyond the supplied data.
        bytes += [255, 255, 0, UInt8(RTM_IFINFO2)]
        let messages = bytes.withUnsafeBytes { SystemStatusSampler.networkInterfaceMessages(in: $0) }
        XCTAssertEqual(messages.count, 1)
        let result = try XCTUnwrap(messages.first)
        XCTAssertEqual(result.ifm_index, 7)
        XCTAssertEqual(result.ifm_data.ifi_ibytes, 10_000_000_000)
    }

    func testCPUPowerCombinesDiesWithoutCountingPackageEnergyTwice() throws {
        let previous = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(
            channels: ["DIE_0_CPU Energy": 100, "DIE_1_CPU Energy": 200], uptime: 10
        ))
        let current = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(
            channels: ["DIE_0_CPU Energy": 110, "DIE_1_CPU Energy": 230], uptime: 12
        ))
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: current, previous: previous), 20)
        let package = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(
            channels: ["CPU Energy": 340, "DIE_0_CPU Energy": 110, "DIE_1_CPU Energy": 230], uptime: 12
        ))
        XCTAssertEqual(package.joules, 340)
        XCTAssertNil(SystemStatusPowerCalculator.watts(current: package, previous: previous))
        XCTAssertEqual(SystemStatusPowerNormalizer.energyJoules(from: 2_000, unit: "mJ"), 2)
        XCTAssertNil(SystemStatusPowerNormalizer.energyJoules(from: -.infinity, unit: "mJ"))
    }

    func testCPUPowerUsesSourceTimingToDistinguishFreshZeroStalledAndResumedSamples() throws {
        func sample(_ joules: Double, collected: TimeInterval, source: TimeInterval) throws -> SystemStatusPowerEnergySample {
            try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(
                channels: ["CPU Energy": joules], uptime: collected, sourceUptimes: ["CPU Energy": source]
            ))
        }
        let first = try sample(100, collected: 1_000, source: 500)
        let repeated = try sample(100, collected: 1_002, source: 500)
        XCTAssertNil(SystemStatusPowerCalculator.watts(current: repeated, previous: first))
        let freshZero = try sample(100, collected: 1_004, source: 502)
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: freshZero, previous: repeated), 0)
        let resumed = try sample(110, collected: 1_004, source: 504)
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: resumed, previous: repeated), 2.5)
        let advancingEnergy = try sample(110, collected: 1_004, source: 500)
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: advancingEnergy, previous: repeated), 5)
        let missingMetadata = try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(channels: ["CPU Energy": 110], uptime: 1_004))
        XCTAssertEqual(SystemStatusPowerCalculator.watts(current: missingMetadata, previous: repeated), 5)
    }

    func testCPUPowerTrackerRetainsSlowProviderReadingsWithoutKeepingStaleOrResetValues() throws {
        func sample(_ joules: Double, collected: TimeInterval, source: TimeInterval) throws -> SystemStatusPowerEnergySample {
            try XCTUnwrap(SystemStatusCPUPowerReader.cpuEnergySample(
                channels: ["CPU Energy": joules], uptime: collected, sourceUptimes: ["CPU Energy": source]
            ))
        }
        var tracker = SystemStatusPowerTracker()
        XCTAssertNil(tracker.watts(sample: try sample(100, collected: 10, source: 10)))
        XCTAssertEqual(tracker.watts(sample: try sample(110, collected: 12, source: 12)), 5)
        XCTAssertEqual(tracker.watts(sample: try sample(110, collected: 15, source: 12)), 5)
        XCTAssertNil(tracker.watts(sample: try sample(110, collected: 73, source: 12)))
        XCTAssertEqual(tracker.watts(sample: try sample(174, collected: 76, source: 76)), 1)
        XCTAssertNil(tracker.watts(sample: try sample(1, collected: 78, source: 78)))
        XCTAssertEqual(tracker.watts(sample: try sample(5, collected: 80, source: 80)), 2)
        XCTAssertNil(tracker.watts(sample: nil))
        XCTAssertEqual(tracker.watts(sample: try sample(9, collected: 82, source: 82)), 2)
    }

    func testCPUReportTimestampDecodingRejectsUnknownLayouts() throws {
        var element: [UInt64] = [1, 2, 1 | (1 << 32), 1_000, 0, 0, 0, 0]
        let first = try XCTUnwrap(SystemStatusCPUPowerReader.channelUptime(rawElements: element.withUnsafeBytes { Data($0) }))
        element[3] = 2_000
        let second = try XCTUnwrap(SystemStatusCPUPowerReader.channelUptime(rawElements: element.withUnsafeBytes { Data($0) }))
        XCTAssertGreaterThan(first, 0)
        XCTAssertEqual(second, first * 2)
        element[2] = 3 | (1 << 32)
        XCTAssertNil(SystemStatusCPUPowerReader.channelUptime(rawElements: element.withUnsafeBytes { Data($0) }))
        XCTAssertNil(SystemStatusCPUPowerReader.channelUptime(rawElements: Data([0])))
    }

    func testBatteryUsesOnlyPresentInternalBatteryAndStateValidEstimates() throws {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 80, kIOPSMaxCapacityKey: 100]
        var battery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
            kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 80,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: false,
            kIOPSTimeToEmptyKey: 90, kIOPSTimeToFullChargeKey: 30
        ]
        XCTAssertNil(SystemStatusSampler.internalBatteryDescription(in: [ups]))
        let selected = try XCTUnwrap(SystemStatusSampler.internalBatteryDescription(in: [ups, battery]))
        XCTAssertEqual(SystemStatusSampler.batteryLevel(from: selected), 0.5)
        XCTAssertNil(SystemStatusSampler.batteryLevel(from: [:]))
        XCTAssertNil(SystemStatusSampler.batteryRemainingMinutes(from: battery))
        battery[kIOPSIsChargingKey] = true
        XCTAssertEqual(SystemStatusSampler.batteryRemainingMinutes(from: battery), 30)
        battery[kIOPSIsChargingKey] = false
        battery[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        XCTAssertEqual(SystemStatusSampler.batteryRemainingMinutes(from: battery), 90)
        battery[kIOPSIsChargingKey] = true
        battery[kIOPSTimeToEmptyKey] = 0
        XCTAssertNil(SystemStatusSampler.batteryRemainingMinutes(from: battery))
        battery[kIOPSIsChargingKey] = false
        battery[kIOPSTimeToEmptyKey] = -1
        XCTAssertNil(SystemStatusSampler.batteryRemainingMinutes(from: battery))
        battery[kIOPSIsPresentKey] = false
        XCTAssertNil(SystemStatusSampler.internalBatteryDescription(in: [battery]))
    }

    func testBatteryCurrentPreservesUnsignedNegativeEncodingAndZero() throws {
        let encoded = UInt64(bitPattern: -1_000)
        for raw: Any in [encoded, NSNumber(value: encoded), String(encoded)] {
            let current = SystemStatusBatteryPowerNormalizer.signedNumberValue(raw)
            XCTAssertEqual(current, -1_000)
            XCTAssertEqual(SystemStatusBatteryPowerNormalizer.derivedWatts(voltageMillivolts: 12_000, amperageMilliamps: current), 12)
        }
        XCTAssertEqual(SystemStatusBatteryPowerNormalizer.derivedWatts(voltageMillivolts: 12_000, amperageMilliamps: 0), 0)
    }

}
