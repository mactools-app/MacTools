import Foundation

/// Main-actor state owner. Scans run off the main actor; only completed
/// snapshots and throttled progress reach published state. The host is
/// notified through `onStateChange` so the panel rebuilds from these snapshots.
@MainActor
public final class SystemDataController: ObservableObject {
    @Published public private(set) var state: SystemDataScanState = .idle
    @Published public private(set) var groups: [SystemDataGroup] = []
    @Published public private(set) var summary: SystemDataScanSummary?

    public var onStateChange: (() -> Void)?

    private let scanner: any SystemDataScanning
    private let definitions: [SystemDataGroupDefinition]
    private var generation = UUID()
    private var scanTask: Task<Void, Never>?

    public init(
        scanner: any SystemDataScanning,
        definitions: [SystemDataGroupDefinition] = SystemDataCatalog.groups
    ) {
        self.scanner = scanner
        self.definitions = definitions
    }

    /// Starts a fresh scan. Any earlier scan is cancelled and its late progress
    /// is dropped by the generation guard.
    public func scan() {
        scanTask?.cancel()
        let generation = UUID()
        self.generation = generation
        state = .scanning(.zero)
        notify()

        let scanner = self.scanner
        scanTask = Task { [weak self] in
            do {
                let result = try await scanner.scan { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        // Never regress a terminal state: the final progress
                        // callback may land after the snapshot was applied.
                        guard self.state.isScanning else { return }
                        self.state = .scanning(progress)
                        self.notify()
                    }
                }
                guard let self, self.generation == generation else { return }
                self.apply(result, generation: generation)
            } catch {
                guard let self, self.generation == generation else { return }
                self.state = error is CancellationError ? .cancelled : .failed(Self.message(for: error))
                self.notify()
            }
        }
    }

    /// Cancels an in-flight scan and keeps the last completed snapshot.
    public func cancel() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        guard state.isScanning else { return }
        state = .cancelled
        notify()
    }

    private func apply(_ result: SystemDataScanResult, generation: UUID) {
        guard self.generation == generation, !Task.isCancelled else { return }
        let rebuilt = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: result.results
        )
        groups = rebuilt
        summary = SystemDataPresentation.makeSummary(
            groups: rebuilt,
            availableBytes: result.availableBytes,
            capacityBytes: result.capacityBytes,
            scannedAt: result.finishedAt
        )
        state = .completed
        notify()
    }

    private static func message(for error: Error) -> String {
        (error as NSError).localizedDescription
    }

    private func notify() {
        onStateChange?()
    }
}
