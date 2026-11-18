import Foundation

struct SystemStatusSamplingDemand: OptionSet, Hashable, Sendable {
    let rawValue: UInt32
    static let cpuUsage = Self(rawValue: 1 << 0)
    static let cpuLoad = Self(rawValue: 1 << 1)
    static let cpuPower = Self(rawValue: 1 << 2)
    static let cpuTemperature = Self(rawValue: 1 << 3)
    static let memoryUsage = Self(rawValue: 1 << 4)
    static let memoryPressure = Self(rawValue: 1 << 5)
    static let swap = Self(rawValue: 1 << 6)
    static let network = Self(rawValue: 1 << 7)
    static let diskActivity = Self(rawValue: 1 << 8)
    static let diskCapacity = Self(rawValue: 1 << 9)
    static let gpuUsage = Self(rawValue: 1 << 10)
    static let gpuTemperature = Self(rawValue: 1 << 11)
    static let battery = Self(rawValue: 1 << 12)
    static let batteryDetails = Self(rawValue: 1 << 13)
    static let batteryHealth = Self(rawValue: 1 << 14)
    static let processes = Self(rawValue: 1 << 15)

    static let cpu: Self = [.cpuUsage, .cpuLoad, .cpuPower, .cpuTemperature]
    static let memory: Self = [.memoryUsage, .memoryPressure, .swap]
    static let gpu: Self = [.gpuUsage, .gpuTemperature]
    static let fast: Self = [.cpu, .memory, .network, .diskActivity]
    static let slow: Self = [.diskCapacity, .gpu, .battery, .batteryDetails, .batteryHealth]
    static let all: Self = [.fast, .slow, .processes]

    static let sources: [Self] = (0..<16).map { Self(rawValue: 1 << $0) }

    var needsFast: Bool { !intersection(.fast).isEmpty }
    var needsSlow: Bool { !intersection(.slow).isEmpty }
    var hasHistory: Bool { !subtracting(.processes).isEmpty }

    static func chart(_ metric: SystemStatusChartMetric, kind: SystemStatusMetricKind) -> Self {
        if metric == .pressure { return kind == .memory ? .memoryPressure : [] }
        if metric == .activity, kind == .network { return .network }
        guard let value = SystemStatusMenuBarValueKind(rawValue: metric.rawValue) else { return [] }
        return menuBarValue(value, kind: kind)
    }

    private static func menuBarValue(_ value: SystemStatusMenuBarValueKind, kind: SystemStatusMetricKind) -> Self {
        switch (kind, value) {
        case (.cpu, .usage): .cpuUsage
        case (.cpu, .load): .cpuLoad
        case (.cpu, .power): .cpuPower
        case (.cpu, .temperature): .cpuTemperature
        case (.gpu, .usage): .gpuUsage
        case (.gpu, .temperature): .gpuTemperature
        case (.memory, .usage), (.memory, .used): .memoryUsage
        case (.memory, .swap): .swap
        case (.disk, .usage), (.disk, .free): .diskCapacity
        case (.disk, .activity), (.disk, .read), (.disk, .write): .diskActivity
        case (.network, .throughput), (.network, .download), (.network, .upload): .network
        case (.battery, .level), (.battery, .timeRemaining), (.battery, .state): .battery
        case (.battery, .power), (.battery, .temperature): [.battery, .batteryDetails]
        default: []
        }
    }

    static func panel(_ kind: SystemStatusMetricKind, metric: SystemStatusChartMetric) -> Self {
        // Include every value actually displayed by the card or detail, including chips and footnotes.
        let supporting: Self = switch kind {
        case .cpu: [.cpuTemperature, .cpuPower, .cpuLoad]
        case .gpu: [.gpuUsage, .gpuTemperature]
        case .memory: [.memoryUsage, .swap]
        case .disk: [.diskCapacity, .diskActivity]
        case .network: .network
        case .battery: [.battery, .batteryDetails, .batteryHealth]
        case .topProcesses: .processes
        }
        return supporting.union(chart(metric, kind: kind))
    }

    static func menuBar(_ items: [SystemStatusMenuBarMetricPreference]) -> Self {
        items.filter(\.isVisible).reduce(into: Self()) { demand, item in
            for value in item.values {
                demand.formUnion(menuBarValue(value, kind: item.kind))
            }
        }
    }

    static func background(configuration: SystemStatusConfiguration) -> Self {
        configuration.visiblePanelMetricKinds.reduce(into: Self()) { demand, kind in
            demand.formUnion(chart(configuration.chartMetric(for: kind), kind: kind))
        }
    }

    static func foreground(
        configuration: SystemStatusConfiguration, panelVisible: Bool, detailKinds: Set<SystemStatusMetricKind>
    ) -> Self {
        var demand = Self()
        for kind in configuration.visiblePanelMetricKinds {
            let metric = configuration.chartMetric(for: kind)
            if panelVisible { demand.formUnion(panel(kind, metric: metric)) }
        }
        for kind in detailKinds {
            demand.formUnion(panel(kind, metric: configuration.chartMetric(for: kind)))
        }
        return demand
    }
}

extension SystemStatusSnapshot {
    mutating func removeUnrequestedValues(_ demand: SystemStatusSamplingDemand) {
        cpu = SystemStatusCPUSnapshot(
            usage: demand.contains(.cpuUsage) ? cpu.usage : nil,
            loadAverage1Minute: demand.contains(.cpuLoad) ? cpu.loadAverage1Minute : nil,
            temperatureCelsius: demand.contains(.cpuTemperature) ? cpu.temperatureCelsius : nil,
            cpuPowerWatts: demand.contains(.cpuPower) ? cpu.cpuPowerWatts : nil,
            isCollecting: demand.contains(.cpuUsage) && cpu.isCollecting,
            usageInterval: demand.contains(.cpuUsage) ? cpu.usageInterval : nil
        )
        memory = SystemStatusMemorySnapshot(
            usedBytes: demand.contains(.memoryUsage) ? memory.usedBytes : nil,
            totalBytes: demand.contains(.memoryUsage) ? memory.totalBytes : nil,
            swapUsedBytes: demand.contains(.swap) ? memory.swapUsedBytes : nil,
            swapTotalBytes: demand.contains(.swap) ? memory.swapTotalBytes : nil,
            pressure: demand.contains(.memoryPressure) ? memory.pressure : nil,
            pressurePercent: demand.contains(.memoryPressure) ? memory.pressurePercent : nil
        )
        disk = SystemStatusDiskSnapshot(
            usedBytes: demand.contains(.diskCapacity) ? disk.usedBytes : nil,
            totalBytes: demand.contains(.diskCapacity) ? disk.totalBytes : nil,
            readBytesPerSecond: demand.contains(.diskActivity) ? disk.readBytesPerSecond : nil,
            writeBytesPerSecond: demand.contains(.diskActivity) ? disk.writeBytesPerSecond : nil,
            activityInterval: demand.contains(.diskActivity) ? disk.activityInterval : nil
        )
        gpu = SystemStatusGPUSnapshot(
            usage: demand.contains(.gpuUsage) ? gpu.usage : nil,
            name: demand.contains(.gpuUsage) ? gpu.name : nil,
            temperatureCelsius: demand.contains(.gpuTemperature) ? gpu.temperatureCelsius : nil,
            isAvailable: !demand.intersection(.gpu).isEmpty && gpu.isAvailable,
            isCollecting: !demand.intersection(.gpu).isEmpty && gpu.isCollecting
        )
        if !demand.contains(.network) { network = .empty }
        if !demand.contains(.battery) {
            battery = .empty
        } else {
            battery = SystemStatusBatterySnapshot(
                isAvailable: battery.isAvailable, level: battery.level, state: battery.state,
                timeRemainingMinutes: battery.timeRemainingMinutes,
                adapterWatts: demand.contains(.batteryDetails) ? battery.adapterWatts : nil,
                batteryPowerWatts: demand.contains(.batteryDetails) ? battery.batteryPowerWatts : nil,
                temperatureCelsius: demand.contains(.batteryDetails) ? battery.temperatureCelsius : nil,
                healthPercent: demand.contains(.batteryHealth) ? battery.healthPercent : nil,
                cycleCount: demand.contains(.batteryDetails) ? battery.cycleCount : nil
            )
        }
        if !demand.contains(.processes) { topProcesses = [] }
        hardware = .empty
    }
}

extension SystemStatusSnapshot {
    // A batch updates only sources whose deadlines were reached. Other enabled
    // sources retain their snapshot without advancing their native counters.
    mutating func merge(_ sample: SystemStatusSnapshot, demand: SystemStatusSamplingDemand) {
        func value<T>(_ source: SystemStatusSamplingDemand, _ new: T, _ old: T) -> T {
            demand.contains(source) ? new : old
        }
        cpu = .init(usage: value(.cpuUsage, sample.cpu.usage, cpu.usage),
            loadAverage1Minute: value(.cpuLoad, sample.cpu.loadAverage1Minute, cpu.loadAverage1Minute),
            temperatureCelsius: value(.cpuTemperature, sample.cpu.temperatureCelsius, cpu.temperatureCelsius),
            cpuPowerWatts: value(.cpuPower, sample.cpu.cpuPowerWatts, cpu.cpuPowerWatts),
            isCollecting: value(.cpuUsage, sample.cpu.isCollecting, cpu.isCollecting),
            usageInterval: value(.cpuUsage, sample.cpu.usageInterval, cpu.usageInterval))
        memory = .init(usedBytes: value(.memoryUsage, sample.memory.usedBytes, memory.usedBytes),
            totalBytes: value(.memoryUsage, sample.memory.totalBytes, memory.totalBytes),
            swapUsedBytes: value(.swap, sample.memory.swapUsedBytes, memory.swapUsedBytes),
            swapTotalBytes: value(.swap, sample.memory.swapTotalBytes, memory.swapTotalBytes),
            pressure: value(.memoryPressure, sample.memory.pressure, memory.pressure),
            pressurePercent: value(.memoryPressure, sample.memory.pressurePercent, memory.pressurePercent))
        disk = .init(usedBytes: value(.diskCapacity, sample.disk.usedBytes, disk.usedBytes),
            totalBytes: value(.diskCapacity, sample.disk.totalBytes, disk.totalBytes),
            readBytesPerSecond: value(.diskActivity, sample.disk.readBytesPerSecond, disk.readBytesPerSecond),
            writeBytesPerSecond: value(.diskActivity, sample.disk.writeBytesPerSecond, disk.writeBytesPerSecond),
            activityInterval: value(.diskActivity, sample.disk.activityInterval, disk.activityInterval))
        if !demand.intersection(.gpu).isEmpty {
            gpu = .init(usage: value(.gpuUsage, sample.gpu.usage, gpu.usage),
                name: sample.gpu.name ?? gpu.name,
                temperatureCelsius: value(.gpuTemperature, sample.gpu.temperatureCelsius, gpu.temperatureCelsius),
                isAvailable: sample.gpu.isAvailable, isCollecting: sample.gpu.isCollecting)
        }
        if demand.contains(.network) { network = sample.network }
        if !demand.intersection([.battery, .batteryDetails, .batteryHealth]).isEmpty {
            // Power readings carry their own source state. A state-only update
            // cannot carry wattage from before a plug-in or unplug event.
            let updatesPowerSource = demand.contains(.battery) || demand.contains(.batteryDetails)
            let state = updatesPowerSource ? sample.battery.state : battery.state
            let cachedWatts = state == battery.state ? battery.batteryPowerWatts : nil
            battery = .init(isAvailable: sample.battery.isAvailable,
                level: value(.battery, sample.battery.level, battery.level),
                state: state,
                timeRemainingMinutes: updatesPowerSource ? sample.battery.timeRemainingMinutes : battery.timeRemainingMinutes,
                adapterWatts: value(.batteryDetails, sample.battery.adapterWatts, battery.adapterWatts),
                batteryPowerWatts: value(.batteryDetails, sample.battery.batteryPowerWatts, cachedWatts),
                temperatureCelsius: value(.batteryDetails, sample.battery.temperatureCelsius, battery.temperatureCelsius),
                healthPercent: value(.batteryHealth, sample.battery.healthPercent, battery.healthPercent),
                cycleCount: value(.batteryDetails, sample.battery.cycleCount, battery.cycleCount))
        }
    }
}
