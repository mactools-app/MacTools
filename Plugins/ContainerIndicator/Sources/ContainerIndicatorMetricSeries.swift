import Foundation

/// One chartable live sample: the value plus the moment it was read, so a
/// hover can name both.
public struct ContainerIndicatorMetricPoint: Hashable, Sendable, Identifiable {
    public let index: Int
    public let timestamp: Date
    public let value: Double

    public var id: Int { index }

    public init(index: Int, timestamp: Date, value: Double) {
        self.index = index
        self.timestamp = timestamp
        self.value = value
    }
}

/// Turns the retained live samples into the numeric series the detail window
/// charts. Each metric has its own availability rules — CPU and disk need two
/// daemon samples — so the mapping skips missing points instead of plotting a
/// fabricated zero.
public enum ContainerIndicatorMetricSeries {
    /// Percentage of the container's configured CPU allotment.
    public static func cpu(_ history: [ContainerPerformance]) -> [ContainerIndicatorMetricPoint] {
        points(history, value: \.cpuPercent)
    }

    /// Resident memory in megabytes.
    public static func memoryMegabytes(
        _ history: [ContainerPerformance]
    ) -> [ContainerIndicatorMetricPoint] {
        points(history) { performance in
            performance.memoryBytes.map { Double($0) / 1_048_576 }
        }
    }

    /// Combined block read and write throughput in kilobytes per second.
    public static func diskKilobytesPerSecond(
        _ history: [ContainerPerformance]
    ) -> [ContainerIndicatorMetricPoint] {
        points(history, value: \.diskTotalBytesPerSecond)
            .map { point in
                ContainerIndicatorMetricPoint(
                    index: point.index,
                    timestamp: point.timestamp,
                    value: point.value / 1024
                )
            }
    }

    private static func points(
        _ history: [ContainerPerformance],
        value: KeyPath<ContainerPerformance, Double?>
    ) -> [ContainerIndicatorMetricPoint] {
        points(history) { $0[keyPath: value] }
    }

    private static func points(
        _ history: [ContainerPerformance],
        value: (ContainerPerformance) -> Double?
    ) -> [ContainerIndicatorMetricPoint] {
        history
            .compactMap { performance in
                value(performance).map { (performance.sampledAt, $0) }
            }
            .enumerated()
            .map { offset, sample in
                ContainerIndicatorMetricPoint(
                    index: offset,
                    timestamp: sample.0,
                    value: sample.1
                )
            }
    }
}
