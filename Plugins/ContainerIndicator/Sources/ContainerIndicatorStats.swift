import Foundation

/// One raw read of `container stats --format json`. Every counter is
/// cumulative, so CPU percentage and throughput only exist once two reads have
/// been compared.
public struct ContainerStatsCounters: Equatable, Sendable {
    public let id: String
    public let cpuUsageUsec: UInt64?
    public let memoryUsageBytes: UInt64?
    public let memoryLimitBytes: UInt64?
    public let blockReadBytes: UInt64?
    public let blockWriteBytes: UInt64?
    public let networkRxBytes: UInt64?
    public let networkTxBytes: UInt64?
    public let numProcesses: UInt64?

    public init(
        id: String,
        cpuUsageUsec: UInt64?,
        memoryUsageBytes: UInt64?,
        memoryLimitBytes: UInt64?,
        blockReadBytes: UInt64?,
        blockWriteBytes: UInt64?,
        networkRxBytes: UInt64?,
        networkTxBytes: UInt64?,
        numProcesses: UInt64?
    ) {
        self.id = id
        self.cpuUsageUsec = cpuUsageUsec
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes
        self.numProcesses = numProcesses
    }
}

/// Pure counter math behind the live line, kept out of the controller so the
/// delta rules are testable without a running daemon.
public enum ContainerIndicatorStatsMath {
    /// CPU percentage of the container's configured cores: `100` means every
    /// allotted core is busy. Returns nil for the first sample, a
    /// non-positive interval, or a counter reset.
    public static func cpuPercent(
        previous: UInt64?,
        current: UInt64?,
        elapsed: TimeInterval,
        cores: Int
    ) -> Double? {
        guard let previous, let current, current >= previous, elapsed > 0 else {
            return nil
        }
        let usedSeconds = Double(current - previous) / 1_000_000
        return usedSeconds / elapsed / Double(max(1, cores)) * 100
    }

    /// Bytes per second between two cumulative counters. Nil for the first
    /// sample, a non-positive interval, or a counter reset.
    public static func rate(
        previous: UInt64?,
        current: UInt64?,
        elapsed: TimeInterval
    ) -> Double? {
        guard let previous, let current, current >= previous, elapsed > 0 else {
            return nil
        }
        return Double(current - previous) / elapsed
    }

    /// Folds two daemon reads into one display sample. Memory is absolute and
    /// always available; CPU and disk stay nil until a second sample exists.
    public static func performance(
        previous: ContainerStatsCounters?,
        current: ContainerStatsCounters,
        elapsed: TimeInterval,
        cores: Int,
        sampledAt: Date
    ) -> ContainerPerformance {
        ContainerPerformance(
            cpuPercent: cpuPercent(
                previous: previous?.cpuUsageUsec,
                current: current.cpuUsageUsec,
                elapsed: elapsed,
                cores: cores
            ),
            memoryBytes: current.memoryUsageBytes.map { Int(clamping: $0) },
            memoryLimitBytes: current.memoryLimitBytes.map { Int(clamping: $0) },
            diskReadBytesPerSecond: rate(
                previous: previous?.blockReadBytes,
                current: current.blockReadBytes,
                elapsed: elapsed
            ),
            diskWriteBytesPerSecond: rate(
                previous: previous?.blockWriteBytes,
                current: current.blockWriteBytes,
                elapsed: elapsed
            ),
            sampledAt: sampledAt
        )
    }
}
