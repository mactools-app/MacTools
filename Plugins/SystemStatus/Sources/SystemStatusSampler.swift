import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacToolsPluginKit
import OSLog
import SystemConfiguration

protocol SystemStatusSampling: Sendable {
    func setDemand(_ demand: SystemStatusSamplingDemand) async
    func collectFast(referenceDate: Date, demand: SystemStatusSamplingDemand) async -> SystemStatusFastSample
    func collectSlow(demand: SystemStatusSamplingDemand) async -> SystemStatusSlowSample
    func collectTopProcesses(limit: Int) async -> [SystemStatusTopProcess]
    func collectPublicIPAddress() async -> String?
}

actor SystemStatusSampler: SystemStatusSampling {
    private let localization: PluginLocalization
    private let processReader = SystemStatusProcessReader()
    private var previousCPUTicks: SystemStatusCPUTicks?
    private var previousCPUUptime: TimeInterval?
    private var cpuPowerTracker = SystemStatusPowerTracker()
    private var cachedCPUTemperature: Double?
    private var cachedGPUTemperature: Double?
    private var lastCPUTemperatureDate: Date?
    private var lastGPUTemperatureDate: Date?
    private var demand: SystemStatusSamplingDemand = []
    private var smcReader: SystemStatusSMCReader?
    private var didAttemptSMC = false
    private var cpuPowerReader: SystemStatusCPUPowerReader?
    private var previousNetworkCounters: [String: SystemStatusNetworkCounter]?
    private var previousNetworkUptime: TimeInterval?
    private var previousDiskIOCounter: SystemStatusDiskIOCounter?
    private var previousDiskIOUptime: TimeInterval?
    private var cachedSystemPowerHealthPercent: Int?
    private var lastSystemPowerHealthDate: Date?
    private var didCacheSystemPowerHealth = false
    private var healthTask: Task<Int?, Never>?
    private var cachedNetworkMetadata: [String: NetworkInterfaceMetadata]?
    private var lastNetworkMetadataDate: Date?
    private var cachedPrimaryInterfaceName: String?
    private var lastPrimaryInterfaceDate: Date?
    private var didCachePrimaryInterfaceName = false

    private static let hostPort = mach_host_self()
    private static let systemPowerHealthCacheInterval: TimeInterval = 60 * 60
    private static let networkMetadataCacheInterval: TimeInterval = 10
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SystemStatusSampler"
    )

    init(localization: PluginLocalization = PluginLocalization(bundle: .main)) {
        self.localization = localization
    }

    private var networkInterfaceDisplayNames: NetworkInterfaceDisplayNames {
        NetworkInterfaceDisplayNames(
            wired: localization.string("network.interface.wired", defaultValue: "有线"),
            generic: localization.string("network.interface.generic", defaultValue: "网络"),
            multiple: localization.string("network.interface.multiple", defaultValue: "多接口")
        )
    }

    func setDemand(_ demand: SystemStatusSamplingDemand) async {
        self.demand = demand
        if !demand.contains(.cpuUsage) { previousCPUTicks = nil; previousCPUUptime = nil }
        if !demand.contains(.cpuPower) {
            cpuPowerReader = nil
            cpuPowerTracker = SystemStatusPowerTracker()
        }
        if !demand.contains(.cpuTemperature) { cachedCPUTemperature = nil; lastCPUTemperatureDate = nil }
        if !demand.contains(.gpuTemperature) { cachedGPUTemperature = nil; lastGPUTemperatureDate = nil }
        if demand.intersection([.cpuTemperature, .gpuTemperature]).isEmpty {
            smcReader = nil
            didAttemptSMC = false
        }
        if !demand.contains(.network) { previousNetworkCounters = nil; previousNetworkUptime = nil }
        if !demand.contains(.diskActivity) { previousDiskIOCounter = nil; previousDiskIOUptime = nil }
        if !demand.contains(.batteryHealth) { healthTask?.cancel() }
        if !demand.contains(.processes) { await processReader.cancel() }
    }

    func collectFast(referenceDate: Date, demand: SystemStatusSamplingDemand) async -> SystemStatusFastSample {
        let demand = self.demand.intersection(demand)
        let cpu = demand.intersection(.cpu).isEmpty ? .empty : await collectCPU(referenceDate: referenceDate, demand: demand)
        guard !Task.isCancelled else { return .init(cpu: .empty, memory: .empty, network: .empty, disk: .empty) }
        return SystemStatusFastSample(
            cpu: cpu,
            memory: demand.intersection(.memory).isEmpty ? .empty : Self.collectMemory(demand: demand),
            network: demand.contains(.network) ? collectNetwork(referenceDate: referenceDate) : .empty,
            disk: demand.contains(.diskActivity) ? collectDiskIO() : .empty
        )
    }

    func collectSlow(demand: SystemStatusSamplingDemand) async -> SystemStatusSlowSample {
        let demand = self.demand.intersection(demand)
        let battery = demand.intersection([.battery, .batteryDetails, .batteryHealth]).isEmpty ? .empty : await collectBattery(demand: demand)
        guard !Task.isCancelled else { return .init(disk: .empty, battery: .empty, gpu: .empty, hardware: .empty) }
        return SystemStatusSlowSample(
            disk: demand.contains(.diskCapacity) ? Self.collectDiskCapacity() : .empty,
            battery: battery,
            gpu: demand.intersection(.gpu).isEmpty ? .empty : collectGPU(demand: demand),
            hardware: .empty
        )
    }

    func collectTopProcesses(limit: Int = 3) async -> [SystemStatusTopProcess] {
        guard demand.contains(.processes), !Task.isCancelled else { return [] }
        return await processReader.collect(limit: limit)
    }

    func collectPublicIPAddress() async -> String? {
        guard demand.contains(.network) else { return nil }
        return await Self.collectPublicIPAddress()
    }

    private func readCPUEnergy() -> SystemStatusPowerEnergySample? {
        guard demand.contains(.cpuPower) else { return nil }
        if cpuPowerReader == nil { cpuPowerReader = SystemStatusCPUPowerReader() }
        return cpuPowerReader?.readCPUEnergySample()
    }

    private func temperatureReader() -> SystemStatusSMCReader? {
        if !didAttemptSMC { smcReader = SystemStatusSMCReader(); didAttemptSMC = true }
        return smcReader
    }

    private func collectCPU(referenceDate: Date, demand: SystemStatusSamplingDemand) async -> SystemStatusCPUSnapshot {
        let temperature = demand.contains(.cpuTemperature) ? collectCPUTemperature(referenceDate: referenceDate) : nil
        var currentTicks = demand.contains(.cpuUsage) ? Self.readCPUTicks() : nil
        var tickUptime = ProcessInfo.processInfo.systemUptime
        var tickTimestamp = Date().timeIntervalSince1970
        var currentPowerEnergy = demand.contains(.cpuPower) ? readCPUEnergy() : nil
        if previousCPUTicks == nil, let initialTicks = currentTicks {
            let initialPowerEnergy = currentPowerEnergy
            let initialUptime = tickUptime
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return .empty }
            currentTicks = Self.readCPUTicks()
            tickUptime = ProcessInfo.processInfo.systemUptime
            tickTimestamp = Date().timeIntervalSince1970
            currentPowerEnergy = demand.contains(.cpuPower) ? readCPUEnergy() : nil
            previousCPUTicks = initialTicks
            previousCPUUptime = initialUptime
            if demand.contains(.cpuPower) { _ = cpuPowerTracker.watts(sample: initialPowerEnergy) }
        }
        let cpuSample = currentTicks.flatMap { current in
            previousCPUTicks.flatMap { SystemStatusCPUUsageCalculator.sample(current: current, previous: $0) }
        }
        let usageInterval = cpuSample.flatMap { sample in previousCPUUptime.map {
            SystemStatusSampleInterval(endTimestamp: tickTimestamp, duration: tickUptime - $0,
                counterWeight: sample.totalTicks)
        } }
        if demand.contains(.cpuUsage) {
            previousCPUTicks = currentTicks
            previousCPUUptime = currentTicks == nil ? nil : tickUptime
        }
        return SystemStatusCPUSnapshot(
            usage: cpuSample?.usage,
            loadAverage1Minute: demand.contains(.cpuLoad) ? Self.collectCPULoadAverage() : nil,
            temperatureCelsius: temperature,
            cpuPowerWatts: demand.contains(.cpuPower) ? collectPowerWatts(currentPowerEnergy: currentPowerEnergy) : nil,
            isCollecting: demand.contains(.cpuUsage) && cpuSample == nil,
            usageInterval: usageInterval
        )
    }

    private func collectPowerWatts(currentPowerEnergy: SystemStatusPowerEnergySample?) -> Double? {
        cpuPowerTracker.watts(sample: currentPowerEnergy)
    }

    private func collectCPUTemperature(referenceDate: Date) -> Double? {
        if let lastCPUTemperatureDate, referenceDate.timeIntervalSince(lastCPUTemperatureDate) < 5 {
            return cachedCPUTemperature
        }

        let temperature = Self.collectCPUTemperature(smcReader: temperatureReader())
        cachedCPUTemperature = temperature
        lastCPUTemperatureDate = referenceDate
        return temperature
    }

    private func collectGPUTemperature(referenceDate: Date) -> Double? {
        if let lastGPUTemperatureDate, referenceDate.timeIntervalSince(lastGPUTemperatureDate) < 5 {
            return cachedGPUTemperature
        }

        let temperature = Self.collectGPUTemperature(smcReader: temperatureReader())
        cachedGPUTemperature = temperature
        lastGPUTemperatureDate = referenceDate
        return temperature
    }

    private func collectNetwork(referenceDate: Date) -> SystemStatusNetworkSnapshot {
        let currentCounters = currentNetworkCounters(referenceDate: referenceDate)
        guard !currentCounters.isEmpty else {
            previousNetworkCounters = nil
            previousNetworkUptime = ProcessInfo.processInfo.systemUptime
            return SystemStatusNetworkSnapshot(
                interfaceName: nil,
                ipAddress: nil,
                publicIPAddress: nil,
                downloadBytesPerSecond: nil,
                uploadBytesPerSecond: nil,
                isConnected: false,
                isCollecting: false
            )
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let rate: SystemStatusNetworkRate?
        if
            let previousNetworkCounters,
            let previousNetworkUptime
        {
            rate = SystemStatusNetworkRateCalculator.rate(
                current: currentCounters,
                previous: previousNetworkCounters,
                elapsedSeconds: uptime - previousNetworkUptime
            )
        } else {
            rate = nil
        }

        let interval = rate.flatMap { _ in previousNetworkUptime.map {
            SystemStatusSampleInterval(endTimestamp: Date().timeIntervalSince1970, duration: uptime - $0)
        } }
        previousNetworkCounters = currentCounters
        previousNetworkUptime = uptime

        let singleInterface = currentCounters.count == 1 ? currentCounters.values.first : nil
        let primaryInterface = primaryInterfaceName(referenceDate: referenceDate).flatMap { currentCounters[$0] }
        return SystemStatusNetworkSnapshot(
            interfaceName: singleInterface?.displayName ?? networkInterfaceDisplayNames.multiple,
            ipAddress: primaryInterface?.ipAddress ?? singleInterface?.ipAddress,
            publicIPAddress: nil,
            downloadBytesPerSecond: rate?.downloadBytesPerSecond,
            uploadBytesPerSecond: rate?.uploadBytesPerSecond,
            isConnected: true,
            isCollecting: rate == nil,
            activityInterval: interval
        )
    }

    private static func readCPUTicks() -> SystemStatusCPUTicks? {
        let count = MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        var size = mach_msg_type_number_t(count)
        var info = host_cpu_load_info()

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: count) { reboundPointer in
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, reboundPointer, &size)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return SystemStatusCPUTicks(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
    }

    private static func collectCPULoadAverage() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, Int32(averages.count)) > 0 else {
            return nil
        }

        let load = averages[0]
        guard load >= 0, load.isFinite else {
            return nil
        }

        return load
    }

    private static func collectCPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        if let smcTemperature = collectSMCCPUTemperature(smcReader: smcReader) {
            return smcTemperature
        }

        let values = collectHIDSensorTemperatures(
            keyPrefixes: ["pACC MTR Temp", "eACC MTR Temp"]
        )

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectSMCCPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        guard let smcReader else {
            return nil
        }

        let directKeys = ["TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCAD"]
        for key in directKeys {
            if let value = smcReader.value(for: key), isValidTemperature(value) {
                return value
            }
        }

        let appleSiliconKeys = [
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
            "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
            "Te05", "Te09", "Te0H", "Te0L", "Te0P", "Te0S",
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
            "Tp0V", "Tp0Y", "Tp0e",
            "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
        ]
        let values = appleSiliconKeys.compactMap { key in
            smcReader.value(for: key)
        }.filter(isValidTemperature)

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectGPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        if let smcTemperature = collectSMCGPUTemperature(smcReader: smcReader) {
            return smcTemperature
        }

        let values = collectHIDSensorTemperatures(
            keyPrefixes: ["GPU MTR Temp"]
        )

        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private static func collectSMCGPUTemperature(smcReader: SystemStatusSMCReader?) -> Double? {
        guard let smcReader else {
            return nil
        }

        let keys = [
            "TCGC", "TG0D", "TGDD", "TG0H", "TG0P", "TG0T", "TG1D", "TG1P", "TG1H", "TG1T",
            "Tg05", "Tg0D", "Tg0L", "Tg0T",
            "Tg0f", "Tg0j",
            "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",
            "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0U", "Tg0X", "Tg0g", "Tg1Y", "Tg1c", "Tg1g"
        ]
        let values = keys.compactMap { smcReader.value(for: $0) }.filter(isValidTemperature)
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    nonisolated static func hidSensorTemperatures(output: String, keyPrefixes: [String]) -> [Double] {
        let lines = output.components(separatedBy: .newlines)
        var isMatchingSensor = false
        var values: [Double] = []

        for line in lines {
            if line.contains("+-o ") || line.contains("| +-o ") {
                isMatchingSensor = keyPrefixes.contains { line.localizedCaseInsensitiveContains($0) }
            } else if keyPrefixes.contains(where: { line.localizedCaseInsensitiveContains($0) }) {
                isMatchingSensor = true
            }

            guard isMatchingSensor else {
                continue
            }

            let celsiusValues = regexCaptures(#"temperature[^=]*=\s*([0-9]+(?:\.[0-9]+)?)"#, in: line)
                .compactMap(Double.init)
                .map(normalizedTemperatureCelsius)
                .filter(isValidTemperature)

            values.append(contentsOf: celsiusValues)
        }

        return values
    }

    private static func collectHIDSensorTemperatures(keyPrefixes: [String]) -> [Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDEventService"),
            &iterator
        ) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var rawProperties: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = rawProperties?.takeRetainedValue() as? [String: Any],
                hidSensorMatches(properties: properties, keyPrefixes: keyPrefixes)
            else {
                continue
            }

            for key in ["temperature", "Temperature"] {
                if
                    let rawTemperature = numberValue(properties[key]),
                    isValidTemperature(normalizedTemperatureCelsius(rawTemperature))
                {
                    values.append(normalizedTemperatureCelsius(rawTemperature))
                    break
                }
            }
        }

        return values
    }

    private static func hidSensorMatches(properties: [String: Any], keyPrefixes: [String]) -> Bool {
        let candidates = ["Product", "product", "name", "Name", "IOName"].compactMap { key in
            stringValue(properties[key] as Any)
        }

        return candidates.contains { candidate in
            keyPrefixes.contains { candidate.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func isValidTemperature(_ value: Double) -> Bool {
        value > 0 && value < 110
    }

    private static func collectMemory(demand: SystemStatusSamplingDemand) -> SystemStatusMemorySnapshot {
        let pressure = demand.contains(.memoryPressure) ? collectMemoryPressure() : nil
        let swap = demand.contains(.swap) ? collectSwapUsage() : (used: nil, total: nil)
        let unavailable = SystemStatusMemorySnapshot(usedBytes: nil, totalBytes: nil,
            swapUsedBytes: swap.used, swapTotalBytes: swap.total, pressure: pressure)
        guard !demand.intersection([.memoryUsage, .memoryPressure]).isEmpty else { return unavailable }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(hostPort, HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return unavailable
        }

        return memorySnapshot(stats: stats, pageSize: memoryPageSize().map { UInt64($0) },
            totalBytes: ProcessInfo.processInfo.physicalMemory, demand: demand, pressure: pressure, swap: swap)
    }

    nonisolated static func memorySnapshot(
        stats: vm_statistics64, pageSize: UInt64?, totalBytes: UInt64,
        demand: SystemStatusSamplingDemand, pressure: SystemStatusMemoryPressure?,
        swap: (used: UInt64?, total: UInt64?) = (nil, nil)
    ) -> SystemStatusMemorySnapshot {
        var snapshot = SystemStatusMemorySnapshot(usedBytes: nil, totalBytes: nil,
            swapUsedBytes: swap.used, swapTotalBytes: swap.total, pressure: pressure)
        guard let pageSize, pageSize > 0, totalBytes > 0 else { return snapshot }
        if demand.contains(.memoryPressure) {
            snapshot.pressurePercent = SystemStatusMemoryPressure.estimatedPercentage(
                wiredPages: stats.wire_count, compressorPages: stats.compressor_page_count,
                pageSize: pageSize, totalBytes: totalBytes)
        }
        guard demand.contains(.memoryUsage) else { return snapshot }
        let bytesPerPage = Double(pageSize)
        let active = Double(stats.active_count) * bytesPerPage
        let speculative = Double(stats.speculative_count) * bytesPerPage
        let inactive = Double(stats.inactive_count) * bytesPerPage
        let wired = Double(stats.wire_count) * bytesPerPage
        let compressed = Double(stats.compressor_page_count) * bytesPerPage
        let purgeable = Double(stats.purgeable_count) * bytesPerPage
        let external = Double(stats.external_page_count) * bytesPerPage
        let rawUsed = active + inactive + speculative + wired + compressed - purgeable - external
        return SystemStatusMemorySnapshot(
            usedBytes: UInt64(min(max(rawUsed, 0), Double(totalBytes))), totalBytes: totalBytes,
            swapUsedBytes: swap.used, swapTotalBytes: swap.total,
            pressure: pressure, pressurePercent: snapshot.pressurePercent)
    }

    static func collectMemoryPressure() -> SystemStatusMemoryPressure? {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return nil }
        return SystemStatusMemoryPressure(rawValue: Int(level))
    }

    private func collectGPU(demand: SystemStatusSamplingDemand) -> SystemStatusGPUSnapshot {
        Self.gpuSample(demand: demand, registryReadings: Self.readGPURegistry) {
            collectGPUTemperature(referenceDate: Date())
        }
    }

    nonisolated static func gpuSample(
        demand: SystemStatusSamplingDemand,
        registryReadings: () -> [SystemStatusGPUSnapshot],
        fallbackTemperature: () -> Double?
    ) -> SystemStatusGPUSnapshot {
        guard !demand.intersection(.gpu).isEmpty else { return .empty }
        // Temperature(C) remains available without requesting utilization.
        // Device selection is shared so opening a panel cannot change its source.
        let readings = registryReadings()
        let native = gpuSnapshot(readings: readings, fallbackTemperature: nil)
        let fallback = demand.contains(.gpuTemperature) && native.temperatureCelsius == nil && readings.count <= 1
            ? fallbackTemperature() : nil
        let selected = gpuSnapshot(readings: readings, fallbackTemperature: fallback)
        return .init(usage: demand.contains(.gpuUsage) ? selected.usage : nil,
            name: selected.name,
            temperatureCelsius: demand.contains(.gpuTemperature) ? selected.temperatureCelsius : nil,
            isAvailable: selected.isAvailable, isCollecting: false)
    }

    private static func readGPURegistry() -> [SystemStatusGPUSnapshot] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var readings: [SystemStatusGPUSnapshot] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let statistics = Self.registryPerformanceStatistics(service: service)
            readings.append(SystemStatusGPUSnapshot(
                usage: statistics.flatMap(Self.gpuUtilization),
                name: Self.gpuName(service: service),
                temperatureCelsius: statistics.flatMap(Self.gpuPerformanceTemperature),
                isAvailable: true,
                isCollecting: false
            ))
        }
        return readings
    }

    nonisolated static func gpuSnapshot(
        readings: [SystemStatusGPUSnapshot], fallbackTemperature: Double?
    ) -> SystemStatusGPUSnapshot {
        // Keep the name, utilization and temperature attached to the same GPU.
        let selected = readings.max { ($0.usage ?? -1) < ($1.usage ?? -1) }
        return SystemStatusGPUSnapshot(
            usage: selected?.usage,
            name: selected?.name,
            temperatureCelsius: selected?.temperatureCelsius ?? (readings.count <= 1 ? fallbackTemperature : nil),
            isAvailable: selected != nil || fallbackTemperature != nil,
            isCollecting: false
        )
    }

    nonisolated static func gpuUtilization(from performanceStatistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            guard let value = gpuUtilizationValue(performanceStatistics[key]) else {
                continue
            }

            return value
        }

        return nil
    }

    private static func gpuUtilizationValue(_ rawValue: Any?) -> Double? {
        guard let value = numberValue(rawValue), value.isFinite, (0 ... 100).contains(value) else { return nil }
        return value / 100
    }

    nonisolated static func gpuPerformanceTemperature(from performanceStatistics: [String: Any]) -> Double? {
        guard let value = numberValue(performanceStatistics["Temperature(C)"]), isValidTemperature(value) else {
            return nil
        }

        return value
    }

    nonisolated static func gpuName(from properties: [String: Any]) -> String? {
        gpuName { key in
            properties[key]
        }
    }

    private static func gpuName(service: io_registry_entry_t) -> String? {
        gpuName { key in
            registryRawValue(service: service, key: key)
        }
    }

    private static func gpuName(rawValueForKey: (String) -> Any?) -> String? {
        for key in ["model", "IOName", "name"] {
            guard let rawValue = rawValueForKey(key) else {
                continue
            }

            if let value = stringValue(rawValue), isUserVisibleGPUName(value) {
                return normalizedGPUName(value)
            }
        }

        return nil
    }

    private static func isUserVisibleGPUName(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return !value.isEmpty
            && !lowercased.contains("ioaccelerator")
            && !lowercased.contains("accelerator")
            && !lowercased.contains("controller")
    }

    private static func normalizedGPUName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Apple ", with: "")
    }

    private static func memoryPageSize() -> vm_size_t? {
        var pageSize: vm_size_t = 0
        let result = host_page_size(hostPort, &pageSize)
        guard result == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }

        return pageSize
    }

    private static func collectSwapUsage() -> (used: UInt64?, total: UInt64?) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        guard sysctl(&mib, UInt32(mib.count), &usage, &size, nil, 0) == 0 else {
            return (nil, nil)
        }

        let total = usage.xsu_total > 0 ? usage.xsu_total : nil
        let used = usage.xsu_used > 0 ? usage.xsu_used : UInt64(0)
        return (used, total)
    }

    private static func collectDiskCapacity() -> SystemStatusDiskSnapshot {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        var totalBytes: UInt64?
        var availableBytes: UInt64?

        do {
            let values = try homeURL.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            if let totalCapacity = values.volumeTotalCapacity, totalCapacity > 0 {
                totalBytes = UInt64(totalCapacity)
            }
            if let importantCapacity = values.volumeAvailableCapacityForImportantUsage, importantCapacity >= 0 {
                availableBytes = UInt64(importantCapacity)
            }
        } catch {
            totalBytes = nil
            availableBytes = nil
        }

        if totalBytes == nil || availableBytes == nil {
            if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: homeURL.path) {
                if totalBytes == nil, let total = attributes[.systemSize] as? NSNumber {
                    totalBytes = total.uint64Value
                }
                if availableBytes == nil, let free = attributes[.systemFreeSize] as? NSNumber {
                    availableBytes = free.uint64Value
                }
            }
        }

        guard let totalBytes, totalBytes > 0, let availableBytes else {
            return .empty
        }

        let clampedAvailable = min(availableBytes, totalBytes)
        return SystemStatusDiskSnapshot(
            usedBytes: totalBytes - clampedAvailable,
            totalBytes: totalBytes,
            readBytesPerSecond: nil,
            writeBytesPerSecond: nil
        )
    }

    private func collectDiskIO() -> SystemStatusDiskSnapshot {
        guard let currentCounter = Self.readDiskIOCounter() else {
            previousDiskIOCounter = nil
            previousDiskIOUptime = ProcessInfo.processInfo.systemUptime
            return SystemStatusDiskSnapshot(
                usedBytes: nil,
                totalBytes: nil,
                readBytesPerSecond: nil,
                writeBytesPerSecond: nil
            )
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        let rate: SystemStatusDiskIORate?
        if let previousDiskIOCounter, let previousDiskIOUptime {
            rate = SystemStatusDiskIORateCalculator.rate(
                current: currentCounter,
                previous: previousDiskIOCounter,
                elapsedSeconds: uptime - previousDiskIOUptime
            )
        } else {
            rate = nil
        }

        let interval = rate.flatMap { _ in previousDiskIOUptime.map {
            SystemStatusSampleInterval(endTimestamp: Date().timeIntervalSince1970, duration: uptime - $0)
        } }
        previousDiskIOCounter = currentCounter
        previousDiskIOUptime = uptime

        return SystemStatusDiskSnapshot(
            usedBytes: nil,
            totalBytes: nil,
            readBytesPerSecond: rate?.readBytesPerSecond,
            writeBytesPerSecond: rate?.writeBytesPerSecond,
            activityInterval: interval
        )
    }

    private static func readDiskIOCounter() -> SystemStatusDiskIOCounter? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var devices: [UInt64: SystemStatusDiskIOCounter.Device] = [:]
        var service = IOIteratorNext(iterator)

        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var rawProperties: Unmanaged<CFMutableDictionary>?
            guard
                IORegistryEntryCreateCFProperties(service, &rawProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                let properties = rawProperties?.takeRetainedValue() as? [String: Any],
                let statistics = properties["Statistics"] as? [String: Any]
            else {
                // Some matched drivers do not expose activity statistics.
                // They must not hide the readable disks; identity changes
                // still rebaseline the supported-device set for one interval.
                continue
            }

            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                  let read = statistics["Bytes (Read)"] as? NSNumber,
                  let write = statistics["Bytes (Write)"] as? NSNumber else { continue }
            devices[registryID] = .init(readBytes: read.uint64Value, writeBytes: write.uint64Value)
        }

        return devices.isEmpty ? nil : SystemStatusDiskIOCounter(devices: devices)
    }

    private func collectBattery(demand: SystemStatusSamplingDemand) async -> SystemStatusBatterySnapshot {
        guard
            let powerSourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let powerSources = IOPSCopyPowerSourcesList(powerSourcesInfo)?.takeRetainedValue() as? [CFTypeRef],
            !powerSources.isEmpty
        else {
            return SystemStatusBatterySnapshot(
                isAvailable: false,
                level: nil,
                state: .unavailable,
                timeRemainingMinutes: nil,
                adapterWatts: demand.contains(.batteryDetails) ? Self.adapterWatts() : nil,
                batteryPowerWatts: nil,
                temperatureCelsius: nil,
                healthPercent: nil,
                cycleCount: nil
            )
        }

        let descriptions = powerSources.compactMap { source in
            IOPSGetPowerSourceDescription(powerSourcesInfo, source)?.takeUnretainedValue() as? [String: Any]
        }
        guard let description = Self.internalBatteryDescription(in: descriptions) else {
            return SystemStatusBatterySnapshot(
                isAvailable: false,
                level: nil,
                state: .unavailable,
                timeRemainingMinutes: nil,
                adapterWatts: demand.contains(.batteryDetails) ? Self.adapterWatts() : nil,
                batteryPowerWatts: nil,
                temperatureCelsius: nil,
                healthPercent: nil,
                cycleCount: nil
            )
        }

        let level = Self.batteryLevel(from: description)
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = description[kIOPSIsChargedKey] as? Bool ?? false
        let powerSource = description[kIOPSPowerSourceStateKey] as? String ?? ""
        let state = Self.batteryState(
            level: level,
            isCharging: isCharging,
            isCharged: isCharged,
            powerSource: powerSource
        )
        let registryInfo = !demand.intersection([.batteryDetails, .batteryHealth]).isEmpty
            ? Self.collectBatteryRegistryInfo(state: state)
            : (temperatureCelsius: nil, healthPercent: nil, cycleCount: nil, batteryPowerWatts: nil)
        let healthPercent: Int?
        if !demand.contains(.batteryHealth) {
            healthPercent = nil
        } else if let registryHealthPercent = registryInfo.healthPercent {
            healthPercent = registryHealthPercent
        } else {
            healthPercent = await systemPowerHealthPercent(referenceDate: Date())
        }

        return SystemStatusBatterySnapshot(
            isAvailable: true,
            level: level,
            state: state,
            timeRemainingMinutes: Self.batteryRemainingMinutes(from: description),
            adapterWatts: demand.contains(.batteryDetails) ? Self.adapterWatts() : nil,
            batteryPowerWatts: registryInfo.batteryPowerWatts,
            temperatureCelsius: registryInfo.temperatureCelsius,
            healthPercent: healthPercent,
            cycleCount: registryInfo.cycleCount
        )
    }

    private func systemPowerHealthPercent(referenceDate: Date) async -> Int? {
        if didCacheSystemPowerHealth,
           let lastSystemPowerHealthDate,
           referenceDate.timeIntervalSince(lastSystemPowerHealthDate) < Self.systemPowerHealthCacheInterval {
            return cachedSystemPowerHealthPercent
        }

        if let healthTask { return await healthTask.value }
        let task = Task {
            guard let output = await Self.runCommand(
                path: "/usr/sbin/system_profiler", arguments: ["SPPowerDataType", "-json"], timeout: 3
            ), !Task.isCancelled else { return nil as Int? }
            return Self.systemPowerBatteryHealthPercent(fromSystemProfilerJSON: output)
        }
        healthTask = task
        let healthPercent = await task.value
        healthTask = nil
        guard !task.isCancelled else { return nil }

        cachedSystemPowerHealthPercent = healthPercent
        lastSystemPowerHealthDate = referenceDate
        didCacheSystemPowerHealth = true
        return healthPercent
    }

    nonisolated static func internalBatteryDescription(in descriptions: [[String: Any]]) -> [String: Any]? {
        descriptions.first {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && $0[kIOPSIsPresentKey] as? Bool != false
        }
    }

    nonisolated static func batteryLevel(from description: [String: Any]) -> Double? {
        guard let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0,
              let current = description[kIOPSCurrentCapacityKey] as? Int, current >= 0 else { return nil }
        return min(Double(current) / Double(maximum), 1)
    }

    nonisolated static func batteryRemainingMinutes(from description: [String: Any]) -> Int? {
        let isCharging = description[kIOPSIsChargingKey] as? Bool == true
        let key: String
        if description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue {
            // A charging sample can carry a zero placeholder for time to empty.
            guard !isCharging else { return nil }
            key = kIOPSTimeToEmptyKey
        } else if isCharging {
            key = kIOPSTimeToFullChargeKey
        } else {
            return nil
        }
        guard let minutes = description[key] as? Int, minutes >= 0 else { return nil }
        return minutes
    }

    private static func batteryState(
        level: Double?, isCharging: Bool, isCharged: Bool, powerSource: String
    ) -> SystemStatusBatteryState {
        if powerSource == kIOPSBatteryPowerValue { return .unplugged }
        if isCharging { return .charging }
        if powerSource == kIOPSACPowerValue {
            return isCharged || (level ?? 0) >= 0.999 ? .charged : .acPower
        }
        return .unknown
    }

    private static func adapterWatts() -> Int? {
        guard
            let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
            let watts = adapterDetails[kIOPSPowerAdapterWattsKey] as? Int,
            watts > 0
        else {
            return nil
        }

        return watts
    }

    private static func collectBatteryRegistryInfo(state: SystemStatusBatteryState) -> (
        temperatureCelsius: Double?,
        healthPercent: Int?,
        cycleCount: Int?,
        batteryPowerWatts: Double?
    ) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return (nil, nil, nil, nil)
        }
        defer { IOObjectRelease(service) }

        let batteryData = registryDictionaryValue(service: service, key: "BatteryData")
        let batteryPackService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBatteryPack")
        )
        defer {
            if batteryPackService != 0 {
                IOObjectRelease(batteryPackService)
            }
        }
        let batteryPackData = batteryPackService == 0
            ? nil
            : registryDictionaryValue(service: batteryPackService, key: "BatteryData")
        let temperature = batteryTemperatureCelsius(rawValues: [
            registryIntValue(service: service, key: "Temperature"),
            dictionaryIntValue(batteryData, key: "Temperature"),
            batteryPackService == 0 ? nil : registryIntValue(service: batteryPackService, key: "Temperature"),
            dictionaryIntValue(batteryPackData, key: "Temperature"),
            registryIntValue(service: service, key: "VirtualTemperature"),
            dictionaryIntValue(batteryData, key: "VirtualTemperature"),
            batteryPackService == 0 ? nil : registryIntValue(service: batteryPackService, key: "VirtualTemperature"),
            dictionaryIntValue(batteryPackData, key: "VirtualTemperature"),
        ])

        let healthPercent = optionalBatteryHealthPercent(
            designCapacity: registryIntValue(service: service, key: "DesignCapacity"),
            nominalChargeCapacity: registryIntValue(service: service, key: "NominalChargeCapacity"),
            appleRawMaxCapacity: registryIntValue(service: service, key: "AppleRawMaxCapacity")
        )

        return (
            temperature,
            healthPercent,
            registryIntValue(service: service, key: "CycleCount"),
            batteryPowerWatts(state: state) { registryRawValue(service: service, key: $0) }
        )
    }

    nonisolated static func batteryPowerWatts(
        state: SystemStatusBatteryState, registryValue: (String) -> Any?
    ) -> Double? {
        func telemetryWatts(_ rawValue: Any?) -> Double? {
            let watts = SystemStatusBatteryPowerNormalizer.telemetryWatts(fromRawMilliwatts: rawValue)
            return SystemStatusBatteryPowerNormalizer.wattsMatchingPowerSource(watts, state: state)
        }

        let telemetry = registryValue("PowerTelemetryData") as? NSDictionary
        if let watts = telemetryWatts(telemetry?["BatteryPower"])
            ?? telemetryWatts(registryValue("BatteryPower")) {
            return watts
        }

        let voltageMillivolts = registryValue("AppleRawBatteryVoltage").flatMap(numberValue)
            ?? registryValue("Voltage").flatMap(numberValue)
        let amperageMilliamps = SystemStatusBatteryPowerNormalizer.signedNumberValue(registryValue("InstantAmperage"))
            ?? SystemStatusBatteryPowerNormalizer.signedNumberValue(registryValue("Amperage"))

        let watts = SystemStatusBatteryPowerNormalizer.derivedWatts(
            voltageMillivolts: voltageMillivolts,
            amperageMilliamps: amperageMilliamps
        )
        return SystemStatusBatteryPowerNormalizer.wattsMatchingPowerSource(watts, state: state)
    }

    nonisolated static func batteryHealthPercent(
        designCapacity: Int?,
        nominalChargeCapacity: Int?,
        appleRawMaxCapacity: Int?
    ) -> Int {
        // ioreg fallback matching Mole status: prefer NominalChargeCapacity, then AppleRawMaxCapacity.
        optionalBatteryHealthPercent(
            designCapacity: designCapacity,
            nominalChargeCapacity: nominalChargeCapacity,
            appleRawMaxCapacity: appleRawMaxCapacity
        ) ?? 0
    }

    nonisolated static func systemPowerBatteryHealthPercent(fromSystemProfilerJSON output: String) -> Int? {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = json["SPPowerDataType"] as? [[String: Any]]
        else {
            return nil
        }

        for section in sections {
            guard
                let info = section["sppower_battery_health_info"] as? [String: Any],
                let rawCapacity = info["sppower_battery_health_maximum_capacity"] as? String,
                let percent = batteryHealthPercent(fromSystemProfilerValue: rawCapacity)
            else {
                continue
            }

            return percent
        }

        return nil
    }

    nonisolated static func batteryHealthPercent(fromSystemProfilerValue rawValue: String) -> Int? {
        let normalized = rawValue
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(normalized), value > 0 else {
            return nil
        }

        return min(max(value, 0), 100)
    }

    private nonisolated static func optionalBatteryHealthPercent(
        designCapacity: Int?,
        nominalChargeCapacity: Int?,
        appleRawMaxCapacity: Int?
    ) -> Int? {
        guard let designCapacity, designCapacity > 0 else {
            return nil
        }

        let capacity = positiveCapacity(nominalChargeCapacity)
            ?? positiveCapacity(appleRawMaxCapacity)
        guard let capacity else {
            return nil
        }

        let percent = (Double(capacity) * 100 / Double(designCapacity)).rounded()
        guard percent > 0 else {
            return nil
        }

        return min(max(Int(percent), 0), 100)
    }

    private nonisolated static func positiveCapacity(_ value: Int?) -> Int? {
        guard let value, value > 0 else {
            return nil
        }

        return value
    }

    private static func registryIntValue(service: io_registry_entry_t, key: String) -> Int? {
        guard let rawValue = registryRawValue(service: service, key: key) else {
            return nil
        }

        if let intValue = rawValue as? Int {
            return intValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private static func dictionaryIntValue(_ dictionary: NSDictionary?, key: String) -> Int? {
        guard let rawValue = dictionary?[key] else {
            return nil
        }

        if let intValue = rawValue as? Int {
            return intValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    nonisolated static func batteryTemperatureCelsius(rawValues: [Int?]) -> Double? {
        for rawValue in rawValues.compactMap({ $0 }) {
            let celsius = Double(rawValue) / 100
            if celsius.isFinite, (0 ... 100).contains(celsius) {
                return celsius
            }
        }
        return nil
    }

    private static func registryRawValue(service: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func registryDictionaryValue(service: io_registry_entry_t, key: String) -> NSDictionary? {
        guard let rawValue = registryRawValue(service: service, key: key) else {
            return nil
        }

        return rawValue as? NSDictionary
    }

    private static func registryPerformanceStatistics(service: io_registry_entry_t) -> [String: Any]? {
        guard let rawValue = registryRawValue(service: service, key: "PerformanceStatistics") else {
            return nil
        }

        if let value = rawValue as? [String: Any] {
            return value
        }
        if let value = rawValue as? NSDictionary {
            return value as? [String: Any]
        }
        return nil
    }

    private static func dictionaryNumberValue(_ dictionary: NSDictionary, key: String) -> Double? {
        numberValue(dictionary[key])
    }

    private static func numberValue(_ rawValue: Any?) -> Double? {
        if let intValue = rawValue as? Int {
            return Double(intValue)
        }
        if let doubleValue = rawValue as? Double {
            return doubleValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.doubleValue
        }
        if let stringValue = rawValue as? String {
            return Double(stringValue)
        }
        return nil
    }

    private static func stringValue(_ rawValue: Any) -> String? {
        if let value = rawValue as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = rawValue as? Data {
            let trimmed = String(decoding: value, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func currentNetworkCounters(referenceDate: Date) -> [String: SystemStatusNetworkCounter] {
        let counters = Self.readNetworkCounters(
            interfaceMetadata: networkInterfaceMetadata(referenceDate: referenceDate),
            displayNames: networkInterfaceDisplayNames
        )
        return Self.activeNetworkCounters(counters)
    }

    nonisolated static func activeNetworkCounters(
        _ counters: [String: SystemStatusNetworkCounter]
    ) -> [String: SystemStatusNetworkCounter] {
        // Preserve system-wide physical traffic, including simultaneous wired
        // and Wi-Fi transfers, without counting virtual/VPN copies again.
        counters.filter { $0.value.isUp && !isNoiseInterface($0.key) }
    }

    private func networkInterfaceMetadata(referenceDate: Date) -> [String: NetworkInterfaceMetadata] {
        if
            let cachedNetworkMetadata,
            let lastNetworkMetadataDate,
            referenceDate.timeIntervalSince(lastNetworkMetadataDate) < Self.networkMetadataCacheInterval
        {
            return cachedNetworkMetadata
        }

        let metadata = Self.networkInterfaceMetadata()
        cachedNetworkMetadata = metadata
        lastNetworkMetadataDate = referenceDate
        return metadata
    }

    private func primaryInterfaceName(referenceDate: Date) -> String? {
        if didCachePrimaryInterfaceName,
           let lastPrimaryInterfaceDate,
           referenceDate.timeIntervalSince(lastPrimaryInterfaceDate) < Self.networkMetadataCacheInterval {
            return cachedPrimaryInterfaceName
        }

        let name = Self.primaryInterfaceName()
        cachedPrimaryInterfaceName = name
        lastPrimaryInterfaceDate = referenceDate
        didCachePrimaryInterfaceName = true
        return name
    }

    private static func primaryInterfaceName() -> String? {
        for family in ["IPv4", "IPv6"] {
            if let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let name = global["PrimaryInterface"] as? String, !name.isEmpty, !isNoiseInterface(name) {
                return name
            }
        }
        return nil
    }

    private static func readNetworkCounters(
        interfaceMetadata: [String: NetworkInterfaceMetadata],
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> [String: SystemStatusNetworkCounter] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return readInterfaceNetworkCounters(interfaceMetadata: interfaceMetadata, displayNames: displayNames)
        }
        defer { freeifaddrs(interfaceAddresses) }

        var accumulators: [String: NetworkAddressAccumulator] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let currentPointer = pointer {
            defer { pointer = currentPointer.pointee.ifa_next }

            let name = String(cString: currentPointer.pointee.ifa_name)
            var accumulator = accumulators[name] ?? NetworkAddressAccumulator()

            guard let address = currentPointer.pointee.ifa_addr else {
                accumulators[name] = accumulator
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if let address = numericAddress(from: address), !address.hasPrefix("127.") {
                    accumulator.ipv4Address = address
                }
            case AF_INET6:
                if let address = numericAddress(from: address), !address.hasPrefix("fe80") {
                    accumulator.ipv6Address = address
                }
            default:
                break
            }

            accumulators[name] = accumulator
        }

        let counters = readInterfaceNetworkCounters(interfaceMetadata: interfaceMetadata, displayNames: displayNames)
        return Dictionary(uniqueKeysWithValues: counters.map { name, counter in
            (name, SystemStatusNetworkCounter(
                key: counter.key, displayName: counter.displayName,
                receivedBytes: counter.receivedBytes, sentBytes: counter.sentBytes,
                ipAddress: accumulators[name]?.ipv4Address ?? accumulators[name]?.ipv6Address,
                isUp: counter.isUp
            ))
        })
    }

    private static func readInterfaceNetworkCounters(
        interfaceMetadata: [String: NetworkInterfaceMetadata],
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> [String: SystemStatusNetworkCounter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var counters: [String: SystemStatusNetworkCounter] = [:]
        buffer.withUnsafeBytes { rawBuffer in
            let messages = networkInterfaceMessages(in: UnsafeRawBufferPointer(rebasing: rawBuffer[..<length]))
            for message in messages {
                var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                if let pointer = if_indextoname(UInt32(message.ifm_index), &nameBuffer) {
                    let name = String(cString: pointer)
                    counters[name] = SystemStatusNetworkCounter(
                        key: "iflist2:\(message.ifm_index):\(name)",
                        displayName: friendlyNetworkInterfaceName(
                            for: name, metadata: interfaceMetadata[name], displayNames: displayNames
                        ),
                        receivedBytes: message.ifm_data.ifi_ibytes,
                        sentBytes: message.ifm_data.ifi_obytes,
                        ipAddress: nil,
                        isUp: message.ifm_flags & (IFF_UP | IFF_RUNNING) == (IFF_UP | IFF_RUNNING)
                    )
                }
            }
        }
        return counters
    }

    nonisolated static func networkInterfaceMessages(in buffer: UnsafeRawBufferPointer) -> [if_msghdr2] {
        var messages: [if_msghdr2] = []
        var offset = 0
        // All routing messages share only length, version and type. Address
        // messages can be shorter than if_msghdr and must not end the scan.
        let headerSize = 4
        while offset + headerSize <= buffer.count {
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length >= headerSize, length <= buffer.count - offset else { break }
            let type = buffer.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self)
            if Int32(type) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                messages.append(buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self))
            }
            offset += length
        }
        return messages
    }

    private static func numericAddress(from pointer: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(pointer.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        let nullIndex = host.firstIndex(of: 0) ?? host.endIndex
        let bytes = host[..<nullIndex].map { UInt8(bitPattern: $0) }
        let address = String(decoding: bytes, as: UTF8.self)
        return address.isEmpty ? nil : address
    }

    private static func isNoiseInterface(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let noisePrefixes = ["lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi", "ap", "ipsec", "ppp", "tun", "tap", "wg"]
        return noisePrefixes.contains { lowercasedName.hasPrefix($0) }
    }

    private static func networkInterfaceMetadata() -> [String: NetworkInterfaceMetadata] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }

        var metadata: [String: NetworkInterfaceMetadata] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?, !bsdName.isEmpty else {
                continue
            }

            metadata[bsdName] = NetworkInterfaceMetadata(
                localizedName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                interfaceType: SCNetworkInterfaceGetInterfaceType(interface) as String?
            )
        }

        return metadata
    }

    private static func friendlyNetworkInterfaceName(
        for name: String,
        metadata: NetworkInterfaceMetadata?,
        displayNames: NetworkInterfaceDisplayNames = .default
    ) -> String {
        friendlyNetworkInterfaceName(
            for: name,
            localizedName: metadata?.localizedName,
            interfaceType: metadata?.interfaceType,
            wiredDisplayName: displayNames.wired,
            genericDisplayName: displayNames.generic
        )
    }

    nonisolated static func friendlyNetworkInterfaceName(
        for name: String,
        localizedName: String? = nil,
        interfaceType: String? = nil,
        wiredDisplayName: String = "Ethernet",
        genericDisplayName: String = "Network"
    ) -> String {
        let rawName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedName = rawName.lowercased()
        let localizedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localizedDisplayName = localizedName?.isEmpty == false ? localizedName : nil
        let lowercasedLocalizedName = localizedDisplayName?.lowercased() ?? ""
        let lowercasedInterfaceType = interfaceType?.lowercased() ?? ""

        if isVPNInterfaceName(lowercasedName)
            || lowercasedInterfaceType == (kSCNetworkInterfaceTypePPP as String).lowercased()
            || lowercasedInterfaceType == (kSCNetworkInterfaceTypeIPSec as String).lowercased()
            || lowercasedLocalizedName.contains("vpn")
            || lowercasedLocalizedName.contains("tunnel")
        {
            return "VPN"
        }

        if lowercasedInterfaceType == (kSCNetworkInterfaceTypeIEEE80211 as String).lowercased()
            || lowercasedLocalizedName.contains("wi-fi")
            || lowercasedLocalizedName.contains("wifi")
            || lowercasedLocalizedName.contains("airport")
            || lowercasedLocalizedName.contains("无线")
        {
            return "Wi-Fi"
        }

        if lowercasedInterfaceType == (kSCNetworkInterfaceTypeEthernet as String).lowercased()
            || lowercasedName.hasPrefix("eth")
            || lowercasedLocalizedName.contains("ethernet")
            || lowercasedLocalizedName.contains("以太网")
            || lowercasedLocalizedName.contains("有线")
            || lowercasedLocalizedName.contains("lan")
            || lowercasedLocalizedName.contains("thunderbolt")
            || lowercasedLocalizedName.contains("usb")
        {
            return wiredDisplayName
        }

        return localizedDisplayName ?? (rawName.isEmpty ? genericDisplayName : rawName)
    }

    private static func isVPNInterfaceName(_ lowercasedName: String) -> Bool {
        let vpnPrefixes = ["utun", "tun", "tap", "ppp", "ipsec"]
        return vpnPrefixes.contains { lowercasedName.hasPrefix($0) }
    }

    private static func runCommand(path: String, arguments: [String], timeout: TimeInterval = 1) async -> String? {
        guard let result = await SystemStatusCommandRunner.run(
            path: path,
            arguments: arguments,
            timeout: timeout
        ) else {
            logger.error("Failed to launch command at \(path, privacy: .public)")
            return nil
        }

        guard result.completion == .completed, result.terminationStatus == EXIT_SUCCESS else {
            logger.error(
                "Command failed at \(path, privacy: .public), status: \(result.terminationStatus), timed out: \(result.completion == .timedOut)"
            )
            return nil
        }

        guard !result.standardOutput.isEmpty else {
            logger.error("Command returned no output at \(path, privacy: .public)")
            return nil
        }

        return result.standardOutput
    }

    private static func regexCaptures(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: value) else {
                return nil
            }

            return String(value[captureRange])
        }
    }

    private static func normalizedTemperatureCelsius(_ value: Double) -> Double {
        if value > 1_000 {
            return value / 100
        }
        return value
    }

    private static func collectPublicIPAddress() async -> String? {
        let endpoints = [
            URL(string: "https://api.ipify.org")!,
            URL(string: "https://ifconfig.me/ip")!
        ]

        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 2
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode),
                    let rawValue = String(data: data, encoding: .utf8)
                else {
                    continue
                }

                let ipAddress = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPublicIPAddressCandidate(ipAddress) {
                    return ipAddress
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private static func isPublicIPAddressCandidate(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else {
            return false
        }

        let allowedCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        return value.rangeOfCharacter(from: allowedCharacters.inverted) == nil
    }

    private struct NetworkInterfaceMetadata {
        let localizedName: String?
        let interfaceType: String?
    }

    private struct NetworkInterfaceDisplayNames {
        let wired: String
        let generic: String
        let multiple: String

        static let `default` = NetworkInterfaceDisplayNames(
            wired: "Ethernet",
            generic: "Network",
            multiple: "Multiple Interfaces"
        )
    }

    private struct NetworkAddressAccumulator {
        var ipv4Address: String?
        var ipv6Address: String?
    }
}
