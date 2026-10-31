import Combine
import Foundation
import MacToolsPluginKit

/// Main-actor state owner for the panel: it reads the `container` CLI into an
/// immutable snapshot and applies the quick start/stop operations.
@MainActor
public final class ContainerIndicatorController: ObservableObject {
    public static let pollInterval: TimeInterval = 5
    /// At the five-second poll this covers roughly twelve minutes of history.
    public static let performanceHistoryLimit = 150

    @Published public private(set) var snapshot: ContainerSnapshot = .unavailable
    @Published public private(set) var commandPath: String?
    @Published public private(set) var isChecking = false
    @Published public private(set) var isPerformingAction = false
    /// Operation failures win over the latest status-check failure, and survive
    /// the follow-up refresh so the user can still read what went wrong.
    @Published public private(set) var operationErrorMessage: String?
    @Published public private(set) var checkErrorMessage: String?
    /// Retained live samples per running container, oldest first. The detail
    /// window charts them; entries disappear as soon as a container stops.
    @Published public private(set) var performanceHistory: [String: [ContainerPerformance]] = [:]

    public var lastErrorMessage: String? {
        operationErrorMessage ?? checkErrorMessage
    }

    /// Retained live readings stay visible when a refresh fails, so the detail
    /// window uses this to label them instead of presenting them as current.
    /// An inconclusive service check keeps the last entries on screen just like
    /// a failed stats read does.
    public var retainedDataWarning: String? {
        if let statsFailure = snapshot.statsFailure {
            return statsFailure
        }
        guard snapshot.status == .unknown else { return nil }
        return checkErrorMessage ?? localization.string(
            "panel.error.commandFailed",
            defaultValue: "命令执行失败"
        )
    }

    public var onStateChange: (() -> Void)?
    /// The terminal chosen in settings. The launcher falls back to the system
    /// default if the app has since been removed.
    public var terminalApplication: ContainerTerminalApplication = .systemDefault

    private let commandRunner: any ContainerCommandRunning
    private let commandPathProvider: () -> String?
    private let localization: PluginLocalization
    private let terminalLauncher: any ContainerTerminalLaunching
    private let now: () -> Date
    private var pollTask: Task<Void, Never>?
    /// The single refresh currently allowed to publish. Superseding it or
    /// hiding the panel cancels it, which also terminates the CLI command it
    /// is waiting on.
    private var refreshTask: Task<Void, Never>?
    /// Identifies the newest refresh; older ones compare against it and drop
    /// the results they gathered before being replaced.
    private var refreshGeneration: UInt64 = 0
    /// Previous cumulative counters and the moment they were read. Live rates
    /// only exist as a delta, and the baseline is dropped whenever monitoring
    /// pauses so a long gap never turns into an averaged "current" value.
    private var previousStats: [String: ContainerStatsCounters] = [:]
    private var previousStatsAt: Date?
    public private(set) var isMonitoring = false

    public init(
        commandRunner: any ContainerCommandRunning = ContainerCommandRunner(),
        localization: PluginLocalization = PluginLocalization(bundle: .main),
        commandPathProvider: @escaping () -> String? = { ContainerExecutableLocator.locate() },
        terminalLauncher: any ContainerTerminalLaunching = ContainerTerminalLauncher(),
        now: @escaping () -> Date = Date.init
    ) {
        self.commandRunner = commandRunner
        self.localization = localization
        self.commandPath = commandPathProvider()
        self.commandPathProvider = commandPathProvider
        self.terminalLauncher = terminalLauncher
        self.now = now
    }

    public var isCommandAvailable: Bool {
        commandPath != nil
    }

    /// Localized service status line shared by the row and the widget card, so
    /// both surfaces always derive the same copy from the same snapshot.
    public var statusText: String {
        guard isCommandAvailable else {
            return localization.string(
                "panel.error.commandNotFound",
                defaultValue: "未找到 container 命令"
            )
        }

        switch snapshot.status {
        case .running:
            return localization.format(
                "panel.subtitle.runningFormat",
                defaultValue: "服务运行中 · %1$d 个容器 · %2$d 个虚拟机",
                snapshot.containers.count,
                snapshot.machines.count
            )
        case .stopped, .unregistered:
            return localization.string("panel.subtitle.stopped", defaultValue: "服务未运行")
        case .unknown:
            return localization.string(
                "panel.subtitle.checking",
                defaultValue: "正在检查服务状态"
            )
        }
    }

    // MARK: - Monitoring

    /// Starts the visibility-scoped polling loop and performs one immediate check.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        refreshNow()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isMonitoring else { return }
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    public func stopMonitoring() {
        isMonitoring = false
        pollTask?.cancel()
        pollTask = nil
        // A paused monitor has no usable baseline: rates computed across the
        // gap would describe an average instead of the current load.
        previousStats = [:]
        previousStatsAt = nil
        // The chart has no honest way to bridge the pause: a resumed line
        // would describe a gap it never sampled.
        performanceHistory = [:]
        // Cancelling the refresh also cancels the CLI command it is waiting on,
        // so a hidden panel never leaves a `container` process running behind it.
        cancelInFlightRefresh()
    }

    public func refreshNow() {
        Task { [weak self] in
            await self?.refresh()
        }
    }

    /// Runs one refresh. Only the newest request may publish, so a check that
    /// finishes late cannot overwrite state that has since changed.
    public func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh(generation: generation)
        }
        refreshTask = task
        await task.value
    }

    /// Drops any check still in flight: its results describe a state that has
    /// already moved on, and its process must not outlive the panel.
    private func cancelInFlightRefresh() {
        refreshGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        if isChecking {
            isChecking = false
            onStateChange?()
        }
    }

    /// A refresh may only act and publish while it is still the newest one and
    /// has not been cancelled by hiding the panel or by an operation.
    private func isCurrent(generation: UInt64) -> Bool {
        !Task.isCancelled && generation == refreshGeneration
    }

    private func performRefresh(generation: UInt64) async {
        guard isCurrent(generation: generation), !isPerformingAction else { return }
        resolveCommandPathIfNeeded()
        guard let path = commandPath else {
            publish(.unavailable, generation: generation)
            return
        }

        let previous = snapshot
        isChecking = true
        onStateChange?()

        let statusResult: ContainerCommandResult
        do {
            statusResult = try await commandRunner.run(
                executable: path,
                arguments: ["system", "status", "--format", "json"]
            )
        } catch {
            // A spawn/timeout failure is a check failure, not an operation
            // failure. An unreachable service is not an empty one, so the last
            // known entries stay on screen and the error line explains why.
            guard isCurrent(generation: generation) else { return }
            isChecking = false
            checkErrorMessage = localization.string(
                "panel.error.commandFailed",
                defaultValue: "命令执行失败"
            )
            publish(staleSnapshot(status: .unknown), generation: generation)
            return
        }
        guard isCurrent(generation: generation) else { return }

        let status = ContainerIndicatorParser.serviceStatus(
            exitCode: statusResult.exitCode,
            output: statusResult.standardOutput
        )

        guard status == .running else {
            isChecking = false
            previousStats = [:]
            previousStatsAt = nil
            if status == .unknown {
                checkErrorMessage = failureDetail(
                    exitCode: statusResult.exitCode,
                    standardError: statusResult.standardError
                )
            } else {
                checkErrorMessage = nil
            }
            // A stopped or unregistered service genuinely reports no entries;
            // only an inconclusive status keeps the last known ones.
            let keepsEntries = status == .unknown
            publish(
                ContainerSnapshot(
                    status: status,
                    containers: keepsEntries ? previous.containers : [],
                    machines: keepsEntries ? previous.machines : [],
                    updatedAt: now()
                ),
                generation: generation
            )
            return
        }

        // Each list reads independently: a failure keeps the entries from the
        // last successful read and records why, so the card never presents a
        // failed read as an empty list.
        var containers = previous.containers
        var containersFailure: String?
        let containerResult = try? await commandRunner.run(
            executable: path,
            arguments: ["list", "--all", "--format", "json"]
        )
        guard isCurrent(generation: generation) else { return }
        if containerResult?.exitCode == 0 {
            containers = ContainerIndicatorParser.containers(
                fromJSON: containerResult?.standardOutput ?? ""
            )
        } else {
            containersFailure = listFailureMessage(
                label: localization.string(
                    "panel.error.containersReadFailed",
                    defaultValue: "容器列表读取失败"
                ),
                exitCode: containerResult?.exitCode,
                standardError: containerResult?.standardError ?? ""
            )
        }

        var machines = previous.machines
        var machinesFailure: String?
        let machineResult = try? await commandRunner.run(
            executable: path,
            arguments: ["machine", "list", "--format", "json"]
        )
        guard isCurrent(generation: generation) else { return }
        if machineResult?.exitCode == 0 {
            machines = ContainerIndicatorParser.machines(
                fromJSON: machineResult?.standardOutput ?? ""
            )
        } else {
            machinesFailure = listFailureMessage(
                label: localization.string(
                    "panel.error.machinesReadFailed",
                    defaultValue: "虚拟机列表读取失败"
                ),
                exitCode: machineResult?.exitCode,
                standardError: machineResult?.standardError ?? ""
            )
        }

        // Machine images only exist in per-machine inspect output; a failed
        // inspect keeps the previously known image instead of clearing it.
        var resolvedMachines: [ContainerMachine] = []
        for machine in machines {
            let inspectResult = try? await commandRunner.run(
                executable: path,
                arguments: ["machine", "inspect", machine.id]
            )
            guard isCurrent(generation: generation) else { return }
            let image = inspectResult?.exitCode == 0
                ? ContainerIndicatorParser.machineImage(
                    fromInspectJSON: inspectResult?.standardOutput ?? ""
                )
                : ""
            resolvedMachines.append(image.isEmpty ? machine : machine.withImage(image))
        }
        machines = resolvedMachines

        // The image list supplies per-architecture storage sizes; only a
        // successful read replaces them, so a failed one leaves the sizes the
        // carried-over entries already show.
        let imageResult = try? await commandRunner.run(
            executable: path,
            arguments: ["image", "list", "--format", "json"]
        )
        guard isCurrent(generation: generation) else { return }
        if imageResult?.exitCode == 0 {
            let imageStorage = ContainerIndicatorParser.imageStorageSizes(
                fromJSON: imageResult?.standardOutput ?? ""
            )
            containers = containers.map { container in
                let sizes = imageStorage[container.image]
                let bytes = sizes?[container.architecture]
                    ?? sizes?.first { $0.key != "unknown" }?.value
                    ?? sizes?.first?.value
                return container.withImageStorage(bytes)
            }
        }

        // Live counters come from one stats read for every running container.
        // The command samples twice internally, so a refresh takes about two
        // seconds longer while anything runs; with nothing running it is
        // skipped entirely.
        var statsFailure: String?
        if containers.contains(where: \.isRunning) {
            let statsResult = try? await commandRunner.run(
                executable: path,
                arguments: ["stats", "--format", "json", "--no-stream"]
            )
            guard isCurrent(generation: generation) else { return }

            if statsResult?.exitCode == 0 {
                let counters = ContainerIndicatorParser.stats(
                    fromJSON: statsResult?.standardOutput ?? ""
                )
                let sampledAt = now()
                let elapsed = previousStatsAt.map { sampledAt.timeIntervalSince($0) } ?? 0
                containers = containers.map { container in
                    guard container.isRunning else { return container }
                    guard let current = counters[container.id] else {
                        return container.withPerformance(nil)
                    }
                    return container.withPerformance(
                        ContainerIndicatorStatsMath.performance(
                            previous: previousStats[container.id],
                            current: current,
                            elapsed: elapsed,
                            // 100% means every core the container was given is
                            // busy, matching the "CPU N 核" line above it.
                            cores: max(1, container.cpus),
                            sampledAt: sampledAt
                        )
                    )
                }
                previousStats = counters
                previousStatsAt = sampledAt
                recordPerformanceHistory(containers)
            } else {
                statsFailure = listFailureMessage(
                    label: localization.string(
                        "panel.error.statsReadFailed",
                        defaultValue: "性能数据读取失败"
                    ),
                    exitCode: statsResult?.exitCode,
                    standardError: statsResult?.standardError ?? ""
                )
                // A failed read keeps the numbers already on screen; the card
                // marks them as stale with the warning line.
                let previousPerformance = Dictionary(
                    uniqueKeysWithValues: previous.containers.compactMap { container in
                        container.performance.map { (container.id, $0) }
                    }
                )
                containers = containers.map { container in
                    guard container.performance == nil,
                          let performance = previousPerformance[container.id] else {
                        return container
                    }
                    return container.withPerformance(performance)
                }
            }
        } else {
            previousStats = [:]
            previousStatsAt = nil
            performanceHistory = [:]
        }

        isChecking = false
        checkErrorMessage = nil
        publish(
            ContainerSnapshot(
                status: .running,
                containers: containers,
                machines: machines,
                updatedAt: now(),
                containersFailure: containersFailure,
                machinesFailure: machinesFailure,
                statsFailure: statsFailure
            ),
            generation: generation
        )
    }

    /// Appends the newest sample per running container and drops entries for
    /// containers that stopped, so the charts only ever describe what is live.
    private func recordPerformanceHistory(_ containers: [ContainerInstance]) {
        var history = performanceHistory
        var runningIDs: Set<String> = []
        for container in containers where container.isRunning {
            runningIDs.insert(container.id)
            guard let performance = container.performance else { continue }
            var samples = history[container.id, default: []]
            samples.append(performance)
            if samples.count > Self.performanceHistoryLimit {
                samples.removeFirst(samples.count - Self.performanceHistoryLimit)
            }
            history[container.id] = samples
        }
        history = history.filter { runningIDs.contains($0.key) }
        performanceHistory = history
    }

    // MARK: - Operations

    public func setServiceRunning(_ running: Bool) {
        perform(sequences: [running ? ["system", "start"] : ["system", "stop"]])
    }

    public func startContainer(id: String) {
        perform(sequences: [["start", id]])
    }

    public func stopContainer(id: String) {
        perform(sequences: [["stop", id]])
    }

    /// Restart stops first and only starts when the stop succeeded, so a failed
    /// stop never races a duplicate start.
    public func restartContainer(id: String) {
        perform(sequences: [["stop", id], ["start", id]])
    }

    public func startMachine(id: String) {
        perform(sequences: [["machine", "run", "-n", id, "-d"]])
    }

    public func stopMachine(id: String) {
        perform(sequences: [["machine", "stop", id]])
    }

    public func restartMachine(id: String) {
        perform(sequences: [
            ["machine", "stop", id],
            ["machine", "run", "-n", id, "-d"],
        ])
    }

    // MARK: - Terminal

    /// Opens an interactive shell in the user's default terminal. The CLI must
    /// run in a real TTY, so the launcher hands a `.command` script to
    /// LaunchServices instead of spawning the process here.
    public func openTerminal(target: ContainerTerminalTarget) {
        resolveCommandPathIfNeeded()
        guard let path = commandPath else {
            operationErrorMessage = localization.string(
                "panel.error.terminalUnavailable",
                defaultValue: "container 命令不可用"
            )
            onStateChange?()
            return
        }

        operationErrorMessage = nil
        let application = terminalApplication
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.terminalLauncher.launch(
                    target: target,
                    executable: path,
                    application: application
                )
            } catch ContainerTerminalLaunchError.invalidIdentifier {
                self.operationErrorMessage = self.localization.string(
                    "panel.error.terminalInvalidIdentifier",
                    defaultValue: "容器标识无效"
                )
                self.onStateChange?()
            } catch {
                self.operationErrorMessage = self.localization.string(
                    "panel.error.terminalOpenFailed",
                    defaultValue: "无法打开终端"
                )
                self.onStateChange?()
            }
        }
    }

    /// Runs a command sequence as one operation: it stops at the first failure
    /// and publishes exactly one outcome, then refreshes the snapshot.
    private func perform(sequences: [[String]]) {
        guard !isPerformingAction else { return }
        resolveCommandPathIfNeeded()
        guard let path = commandPath else {
            operationErrorMessage = localization.string(
                "panel.error.commandNotFound",
                defaultValue: "未找到 container 命令"
            )
            onStateChange?()
            return
        }

        // Checks that started before this operation describe the state the
        // operation is about to change; drop them instead of letting them win.
        cancelInFlightRefresh()
        isPerformingAction = true
        operationErrorMessage = nil
        onStateChange?()

        Task { [weak self] in
            guard let self else { return }
            var failure: String?
            for arguments in sequences {
                do {
                    let result = try await commandRunner.run(executable: path, arguments: arguments)
                    if result.exitCode != 0 {
                        failure = failureDetail(exitCode: result.exitCode, standardError: result.standardError)
                        break
                    }
                } catch {
                    failure = localization.format(
                        "panel.error.actionFailedFormat",
                        defaultValue: "操作失败：%@",
                        error.localizedDescription
                    )
                    break
                }
            }
            isPerformingAction = false
            operationErrorMessage = failure
            onStateChange?()
            await refresh()
        }
    }

    // MARK: - Helpers

    private func publish(_ newSnapshot: ContainerSnapshot, generation: UInt64) {
        // Only the newest refresh may publish; a superseded one drops the
        // results it gathered before it was replaced.
        guard isCurrent(generation: generation) else { return }
        if snapshot != newSnapshot {
            snapshot = newSnapshot
        }
        onStateChange?()
    }

    /// Keeps the last known entries when a read failed, so an unavailable
    /// service never looks like one that has nothing in it.
    private func staleSnapshot(status: ContainerServiceStatus) -> ContainerSnapshot {
        ContainerSnapshot(
            status: status,
            containers: snapshot.containers,
            machines: snapshot.machines,
            updatedAt: now()
        )
    }

    /// A failed read reports its label, plus the CLI's own first stderr line
    /// when there is one, so the card explains what went wrong.
    private func listFailureMessage(
        label: String,
        exitCode: Int32?,
        standardError: String
    ) -> String {
        guard let exitCode, exitCode != 0 else {
            // The command never produced a result: spawn failure or timeout.
            return label
        }
        let detail = standardError
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            .map { String($0.prefix(160)) }
        guard let detail else { return label }
        return localization.format(
            "panel.error.readFailedDetailFormat",
            defaultValue: "%1$@：%2$@",
            label,
            detail
        )
    }

    private func resolveCommandPathIfNeeded() {
        guard commandPath == nil else { return }
        commandPath = commandPathProvider()
    }

    private func failureDetail(exitCode: Int32, standardError: String) -> String? {
        guard exitCode != 0 else { return nil }

        let lines = standardError
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let detail = lines.first.map { String($0.prefix(160)) }
            ?? localization.string("panel.error.commandFailed", defaultValue: "命令执行失败")
        return localization.format(
            "panel.error.actionFailedFormat",
            defaultValue: "操作失败：%@",
            detail
        )
    }
}
