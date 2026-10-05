import AppKit
import SwiftUI
import MacToolsPluginKit

public final class SystemStatusPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SystemStatusPluginProvider(context: context)
    }
}

@MainActor
private struct SystemStatusPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SystemStatusPlugin(
            storage: context.storage,
            supportDirectory: context.supportDirectory,
            localization: PluginLocalization(bundle: context.resourceBundle)
        )]
    }
}

@MainActor
final class SystemStatusPlugin:
    MacToolsPlugin, PluginActionProviding, PluginActionShortcutSettingsProviding, PluginSettingsPresenting, PluginDashboardPresenting, PluginPortablePreferencesProviding, PluginPortablePreferencesRestorationReporting, PluginPersistentPreferencesChangeSignaling {
    var panelItems: [PluginPanelItem] {
        return [
            .widget(id: "widget", initialPlacement: .dashboard,
                    descriptor: descriptor, state: widgetState,
                    detail: { [weak self] in self?.makePanelDetailContent(detailID: $0, dismiss: $1) },
                    content: { [weak self] context in
                        self?.makeView(context: context) ?? AnyView(EmptyView())
                    })
                .onVisibilityChange { [weak self] visible in
                    if visible { self?.panelItemDidBecomeVisible("widget") }
                    else { self?.panelItemDidBecomeHidden("widget") }
                },
        ]
    }

    private enum ActionID {
        static let showSystemStatus = "show-system-status"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "system-status",
            title: localization.string("metadata.title", defaultValue: "系统状态"),
            iconName: "gauge.with.dots.needle.67percent",
            iconTint: Color(nsColor: .systemTeal),
            order: 10,
            defaultDescription: localization.string("metadata.description", defaultValue: "实时查看系统状态")
        )
    }

    var descriptor: PluginPanelWidgetDescriptor {
        PluginPanelWidgetDescriptor(
            span: PluginPanelWidgetSpan(
                width: 4,
                height: PluginPanelWidgetLayoutMetrics.default.heightSpan(
                    fittingContentHeight: SystemStatusComponentLayout.contentHeight(
                        for: settingsController.configuration.visiblePanelMetricKinds,
                        processLimit: settingsController.configuration.processLimit
                    )
                )
            )!
        )
    }

    private let viewModel: SystemStatusViewModel
    private let settingsController: SystemStatusSettingsController
    private let menuBarMetricsController: SystemStatusMenuBarMetricsController
    private let localization: PluginLocalization
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()
    private var isActivated = true

    init(
        viewModel: SystemStatusViewModel? = nil,
        settingsController: SystemStatusSettingsController? = nil,
        storage: PluginStorage? = nil,
        supportDirectory: URL? = nil,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        let resolvedViewModel = viewModel
            ?? SystemStatusViewModel(
                sampler: SystemStatusSampler(localization: localization),
                historyStore: SystemStatusHistoryStore(
                    fileURL: SystemStatusHistoryStore.defaultFileURL(supportDirectory: supportDirectory)
                )
            )
        let resolvedSettingsController = settingsController
            ?? SystemStatusSettingsController(
                store: SystemStatusPluginStorageConfigurationStore(
                    storage: storage ?? UserDefaultsPluginStorage(pluginID: "system-status")
                )
            )
        self.viewModel = resolvedViewModel
        self.settingsController = resolvedSettingsController
        self.localization = localization
        self.menuBarMetricsController = SystemStatusMenuBarMetricsController(
            viewModel: resolvedViewModel,
            settingsController: resolvedSettingsController,
            localization: localization
        )
        resolvedViewModel.configure(resolvedSettingsController.configuration)
        resolvedSettingsController.onConfigurationChange = { [weak self] in
            guard let self else { return }
            self.viewModel.configure(self.settingsController.configuration)
            onStateChange?()
            persistentPreferencesChanges.didPersist()
        }
    }

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)? {
        didSet {
            menuBarMetricsController.requestConfigurationPresentation = requestSettingsPresentation
        }
    }
    var requestDashboardPresentation: (() -> Void)? {
        didSet {
            menuBarMetricsController.requestDashboardPresentation = requestDashboardPresentation
        }
    }
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }

    var widgetState: PluginPanelWidgetState {
        PluginPanelWidgetState(
            subtitle: metadata.defaultDescription,
            isActive: false,
            isEnabled: true,
            isAvailable: true,
            errorMessage: nil
        )
    }

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionShortcutSettingsConfiguration: PluginActionShortcutSettingsConfiguration {
        PluginActionShortcutSettingsConfiguration(
            title: localization.string(
                "settings.shortcuts.title",
                defaultValue: "快捷键"
            ),
            systemImage: "command",
            actionIDs: [ActionID.showSystemStatus],
            placementAfterSectionID: "menu-bar-metrics"
        )
    }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(
                    providerID: metadata.id,
                    actionID: ActionID.showSystemStatus
                ),
                title: actionTitle,
                description: actionDescription,
                keywords: [metadata.title, actionTitle],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    var settingsPage: PluginSettingsPage? {
        .form(description: metadata.defaultDescription, sections: [
            PluginSettingsSection(
                id: "panel-metrics",
                title: localization.string("settings.panel.title", defaultValue: "组件面板"),
                systemImage: "square.grid.2x2",
                footer: localization.string(
                    "settings.panel.description",
                    defaultValue: "选择显示内容，拖拽排序，展开配置详情。"
                ),
                presentation: .edgeToEdge
            ) { [settingsController, viewModel, localization] _ in
                SystemStatusSettingsView(
                    controller: settingsController,
                    viewModel: viewModel,
                    localization: localization,
                    section: .panel
                )
            },
            PluginSettingsSection(
                id: "menu-bar-metrics",
                title: localization.string("settings.menuBar.title", defaultValue: "菜单栏指标"),
                systemImage: "menubar.rectangle",
                footer: localization.string(
                    "settings.menuBar.description",
                    defaultValue: "选择要显示在菜单栏里的指标。"
                ),
                presentation: .edgeToEdge
            ) { [settingsController, viewModel, localization] _ in
                SystemStatusSettingsView(
                    controller: settingsController,
                    viewModel: viewModel,
                    localization: localization,
                    section: .menuBar
                )
            }
        ])
    }

    func makeView(context: PluginPanelWidgetContext) -> AnyView {
        AnyView(
            SystemStatusComponentView(
                viewModel: viewModel,
                settingsController: settingsController,
                localization: localization,
                onMetricDetail: { kind in
                    context.presentDetail(kind.rawValue)
                }
            )
        )
    }

    func makePanelDetailContent(
        detailID: String,
        dismiss: @escaping () -> Void
    ) -> PluginPanelDetailContent? {
        guard
            let kind = SystemStatusMetricKind(rawValue: detailID),
            kind != .topProcesses
        else {
            return nil
        }

        return PluginPanelDetailContent(
            id: detailID,
            title: kind.title(localization: localization),
            content: AnyView(
                SystemStatusMetricDetailView(
                    viewModel: viewModel,
                    settingsController: settingsController,
                    kind: kind,
                    localization: localization
                )
            )
        )
    }

    func refresh() {
        guard isActivated else {
            return
        }

        viewModel.startBackground()
        menuBarMetricsController.activate()
    }

    func activate(context: PluginRuntimeContext) {
        isActivated = true
        refresh()
    }

    func deactivate(reason: PluginDeactivationReason) {
        isActivated = false
        menuBarMetricsController.stop()
        viewModel.stop()
    }

    func makePortablePreferencesBackup() -> Data? {
        settingsController.makePortablePreferencesBackup()
    }

    func restorePortablePreferences(from data: Data) {
        _ = settingsController.restorePortablePreferences(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        settingsController.restorePortablePreferences(from: data)
    }

    func panelItemDidBecomeVisible(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.startForeground()
    }

    func panelItemDidBecomeHidden(_ surface: String) {
        guard surface == "widget" else {
            return
        }

        viewModel.returnToBackground()
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func handlePermissionAction(id: String) {}
    func handleSettingsAction(_ action: PluginSettingsAction) {}
    func handleShortcutAction(id: String) {}

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.providerID == metadata.id,
              invocation.reference.key.actionID == ActionID.showSystemStatus else {
            return ActionExecutionHandle {
                .failed(message: PluginKitLocalization.actionUnavailable)
            }
        }
        menuBarMetricsController.presentSystemStatus()
        return ActionExecutionHandle { .succeeded() }
    }

    private var actionTitle: String {
        localization.string(
            "action.showSystemStatus.title",
            defaultValue: "显示系统状态"
        )
    }

    private var actionDescription: String {
        localization.string(
            "action.showSystemStatus.description",
            defaultValue: "显示或隐藏菜单栏概览。如果菜单栏指标已隐藏，则改为打开仪表盘。"
        )
    }
}

@MainActor
final class SystemStatusViewModel: ObservableObject {
    enum ForegroundConsumer: Hashable {
        case dashboard
        case menuBarPopover
        case detail(UUID, SystemStatusMetricKind)
    }

    private var configuration = SystemStatusConfiguration.default
    private var processLimit: SystemStatusProcessLimit { configuration.processLimit }
    private var isActive = false
    private var generation = 0
    private var runningMode: SamplingMode?
    private var runningPlan: SystemStatusSamplingPlan?
    private var lastSamples: [SystemStatusSamplingDemand: TimeInterval] = [:]
    private(set) var activeDemand: SystemStatusSamplingDemand = []
    @Published private(set) var snapshot = SystemStatusSnapshot.empty

    private enum SamplingMode: Equatable {
        case background
        case menuBar
        case foreground

        func historyInterval(schedule: SystemStatusSamplingSchedule) -> TimeInterval {
            switch self {
            case .background, .menuBar:
                return schedule.backgroundHistoryInterval
            case .foreground:
                return schedule.foregroundHistoryInterval
            }
        }
    }

    private let sampler: any SystemStatusSampling
    private let historyStore: any SystemStatusHistoryStoring
    private let schedule: SystemStatusSamplingSchedule
    private let uptime: () -> TimeInterval
    private var samplingTask: Task<Void, Never>?
    private var mode: SamplingMode = .background
    private var menuBarMode: SamplingMode?
    private(set) var foregroundConsumers: Set<ForegroundConsumer> = []

    var isSamplingForeground: Bool { mode == .foreground }
    private var lastHistoryDate: Date?
    private var displayHistory: [SystemStatusHistoryPoint] = []
    private var pendingHistory: [SystemStatusHistoryPoint] = []
    private var collectionID = UUID()
    private var didLoadHistory = false
    private var lastDisplayHistoryPublishDate: Date?

    private static let foregroundDisplayHistoryInterval: TimeInterval = 2
    private static let backgroundDisplayHistoryInterval: TimeInterval = 30

    init(
        sampler: any SystemStatusSampling = SystemStatusSampler(),
        historyStore: (any SystemStatusHistoryStoring)? = nil,
        schedule: SystemStatusSamplingSchedule = .production,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sampler = sampler
        self.historyStore = historyStore ?? SystemStatusHistoryStore(
            fileURL: SystemStatusHistoryStore.defaultFileURL(supportDirectory: nil)
        )
        self.schedule = schedule
        self.uptime = uptime
    }

    func configure(_ configuration: SystemStatusConfiguration) {
        let previousLimit = self.configuration.processLimit
        self.configuration = configuration
        if previousLimit != configuration.processLimit { lastSamples[.processes] = nil }
        reconcileSampling(force: previousLimit != configuration.processLimit && activeDemand.contains(.processes))
    }

    func start() { startForeground() }

    func startForeground(for consumer: ForegroundConsumer = .dashboard) {
        guard foregroundConsumers.insert(consumer).inserted else { return }
        isActive = true
        mode = .foreground
        reconcileSampling()
    }

    func startMenuBar() {
        menuBarMode = .menuBar
        isActive = true
        if foregroundConsumers.isEmpty { mode = menuBarMode ?? .background }
        reconcileSampling()
    }

    func stopMenuBar() {
        menuBarMode = nil
        if foregroundConsumers.isEmpty { mode = .background }
        reconcileSampling()
    }

    func startBackground() {
        isActive = true
        reconcileSampling()
    }

    func returnToBackground(from consumer: ForegroundConsumer = .dashboard) {
        foregroundConsumers.remove(consumer)
        if foregroundConsumers.isEmpty { mode = menuBarMode ?? .background }
        reconcileSampling()
    }

    private func samplingPlan(panelVisible: Bool? = nil) -> SystemStatusSamplingPlan {
        let details = Set(foregroundConsumers.compactMap { consumer -> SystemStatusMetricKind? in
            if case let .detail(_, kind) = consumer { return kind }
            return nil
        })
        return SystemStatusSamplingPlan(
            background: .background(configuration: configuration),
            menuBar: .menuBar(configuration.menuBarItems),
            foreground: .foreground(configuration: configuration,
                panelVisible: panelVisible ?? (foregroundConsumers.contains(.dashboard) || foregroundConsumers.contains(.menuBarPopover)),
                detailKinds: details),
            schedule: schedule
        )
    }

    private func reconcileSampling(force: Bool = false) {
        let plan = isActive ? samplingPlan() : SystemStatusSamplingPlan(background: [], menuBar: [], foreground: [], schedule: schedule)
        let demand = plan.demand
        var updated = snapshot
        // Pausing a collector preserves the last displayed reading. Only disabled
        // surfaces or plugin shutdown discard it, even when the sampling plan is unchanged.
        updated.removeUnrequestedValues(isActive ? samplingPlan(panelVisible: true).demand : [])
        guard force || runningPlan != plan || runningMode != mode else {
            publishSnapshotIfChanged(updated)
            return
        }
        // New intervals determine when existing readings are due; reopening a surface
        // must not force another counter read before a useful interval has elapsed.
        lastSamples = lastSamples.filter { demand.contains($0.key) }
        if activeDemand.isEmpty { lastHistoryDate = nil }
        let crossedIdleBoundary = demand.isEmpty || activeDemand.isEmpty
        if demand.hasHistory, !activeDemand.hasHistory { collectionID = UUID() }
        runningPlan = plan
        activeDemand = demand
        runningMode = mode
        generation += 1
        let revision = generation
        samplingTask?.cancel()
        samplingTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await sampler.setDemand(demand)
            guard !Task.isCancelled, revision == generation else { return }
            if !demand.hasHistory { await flushHistory(referenceDate: Date()) }
            guard !Task.isCancelled, revision == generation else { return }
            guard !demand.isEmpty else {
                if revision == generation { samplingTask = nil }
                return
            }
            if demand.hasHistory { await loadHistory() }
            guard !Task.isCancelled, revision == generation else { return }
            await runSamplingLoop(plan: plan, revision: revision)
        }
        // A configuration boundary is an unavailable observation, not an interpolated measurement.
        if crossedIdleBoundary, !displayHistory.isEmpty {
            let gap = SystemStatusHistoryPoint(timestamp: Date().timeIntervalSince1970)
            appendDisplayHistoryPoint(gap, referenceDate: Date())
            pendingHistory.append(gap)
            updated.history = displayHistory
        }
        publishSnapshotIfChanged(updated)
    }

    func refreshSnapshotNow(referenceDate: Date = Date()) async {
        samplingTask?.cancel()
        generation += 1
        let revision = generation
        let demand = samplingPlan(panelVisible: true).demand
        defer {
            if revision == generation {
                if isActive { reconcileSampling(force: true) }
                else {
                    samplingTask = Task { [sampler] in
                        guard !Task.isCancelled else { return }
                        await sampler.setDemand([])
                    }
                }
            }
        }
        var updated = snapshot
        updated.removeUnrequestedValues(demand)
        publishSnapshotIfChanged(updated)
        await sampler.setDemand(demand)
        guard !Task.isCancelled, revision == generation, !demand.isEmpty else { return }
        if demand.hasHistory { await loadHistory() }
        guard !Task.isCancelled, revision == generation else { return }
        await collectSources(demand, referenceDate: referenceDate, revision: revision)
        guard !Task.isCancelled, revision == generation else { return }
        let completedAt = Date()
        recordHistory(referenceDate: completedAt, demand: demand, sampled: demand)
        await persistHistoryIfNeeded(referenceDate: completedAt, mode: .foreground, demand: demand)
    }

    func stop() {
        isActive = false
        menuBarMode = nil
        foregroundConsumers.removeAll()
        mode = .background
        reconcileSampling(force: true)
    }

    private func loadHistory() async {
        guard !didLoadHistory else {
            return
        }

        let referenceDate = Date()
        let revision = generation
        let history = await historyStore.load(referenceDate: referenceDate)
        guard !Task.isCancelled, revision == generation else { return }
        displayHistory = Self.prunedDisplayHistory(history, referenceDate: referenceDate)
        publishDisplayHistory(referenceDate: referenceDate, force: true)
        didLoadHistory = true
    }

    private func runSamplingLoop(plan: SystemStatusSamplingPlan, revision: Int) async {
        while !Task.isCancelled, revision == generation {
            let now = Date()
            let due = plan.due(at: uptime(), lastSamples: lastSamples)
            if !due.isEmpty {
                await collectSources(due, referenceDate: now, revision: revision)
                guard !Task.isCancelled, revision == generation else { return }
                let completedAt = Date()
                recordHistory(referenceDate: completedAt, demand: plan.demand, sampled: due)
                await persistHistoryIfNeeded(referenceDate: completedAt, mode: mode, demand: plan.demand)
            }
            guard !Task.isCancelled, revision == generation else { return }
            let delay = plan.delay(at: uptime(), lastSamples: lastSamples)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    private func collectSources(_ due: SystemStatusSamplingDemand, referenceDate: Date, revision: Int) async {
        var collected = SystemStatusSnapshot.empty
        if due.needsFast {
            let sample = await sampler.collectFast(referenceDate: referenceDate, demand: due.intersection(.fast))
            guard !Task.isCancelled, revision == generation else { return }
            collected.cpu = sample.cpu
            collected.memory = sample.memory
            collected.network = sample.network
            collected.disk = sample.disk
            publishCollectedSnapshot(collected, demand: due.intersection(.fast))
        }
        if due.needsSlow {
            let sample = await sampler.collectSlow(demand: due.intersection(.slow))
            guard !Task.isCancelled, revision == generation else { return }
            collected.disk = collected.disk.replacingCapacity(from: sample.disk)
            collected.gpu = sample.gpu
            collected.battery = sample.battery
            publishCollectedSnapshot(collected, demand: due.intersection(.slow))
        }
        if due.contains(.processes) {
            let processes = await sampler.collectTopProcesses(limit: processLimit.rawValue)
            guard !Task.isCancelled, revision == generation else { return }
            collected.topProcesses = await Self.resolveApplicationNames(for: processes)
            guard !Task.isCancelled, revision == generation else { return }
            publishCollectedSnapshot(collected, demand: .processes)
        }
    }

    private func publishCollectedSnapshot(_ collected: SystemStatusSnapshot, demand: SystemStatusSamplingDemand) {
        let sampledAt = uptime()
        for source in SystemStatusSamplingDemand.sources where demand.contains(source) {
            lastSamples[source] = sampledAt
        }
        var updated = snapshot
        updated.merge(collected, demand: demand)
        if demand.contains(.processes) { updated.topProcesses = collected.topProcesses }
        publishSnapshotIfChanged(updated)
    }

    private func recordHistory(referenceDate: Date, demand: SystemStatusSamplingDemand, sampled sources: SystemStatusSamplingDemand) {
        guard sources.hasHistory else { return }
        // Presentation-only cached readings must not become new historical observations.
        var sampled = snapshot
        sampled.removeUnrequestedValues(demand)
        var point = SystemStatusHistoryPoint(timestamp: referenceDate.timeIntervalSince1970, snapshot: sampled, collectionID: collectionID)
        let rates = SystemStatusHistoryRates(snapshot: sampled, sampled: sources)
        point.rates = rates.isEmpty ? nil : rates
        appendDisplayHistoryPoint(point, referenceDate: referenceDate)
        pendingHistory.append(point)
        if pendingHistory.count > SystemStatusHistoryStore.maximumSampleCount {
            pendingHistory.removeFirst(pendingHistory.count - SystemStatusHistoryStore.maximumSampleCount)
        }
        publishDisplayHistory(referenceDate: referenceDate)
    }

    private func persistHistoryIfNeeded(referenceDate: Date, mode: SamplingMode, demand: SystemStatusSamplingDemand) async {
        guard demand.hasHistory else { return }
        guard shouldRun(lastDate: lastHistoryDate, referenceDate: referenceDate, interval: mode.historyInterval(schedule: schedule)) else {
            return
        }

        lastHistoryDate = referenceDate
        publishDisplayHistory(referenceDate: referenceDate, force: true)
        await flushHistory(referenceDate: referenceDate)
    }

    private func flushHistory(referenceDate: Date) async {
        guard !pendingHistory.isEmpty else { return }
        let batch = pendingHistory
        pendingHistory.removeAll(keepingCapacity: true)
        _ = await historyStore.appendBatch(batch, referenceDate: referenceDate)
    }

    private func shouldRun(lastDate: Date?, referenceDate: Date, interval: TimeInterval) -> Bool {
        guard let lastDate else {
            return true
        }

        return referenceDate.timeIntervalSince(lastDate) >= interval
    }

    private func appendDisplayHistoryPoint(_ point: SystemStatusHistoryPoint, referenceDate: Date) {
        if let lastIndex = displayHistory.indices.last,
           displayHistory[lastIndex].timestamp == point.timestamp {
            displayHistory[lastIndex] = point
            displayHistory = Self.prunedSortedDisplayHistory(displayHistory, referenceDate: referenceDate)
            return
        }

        if let lastTimestamp = displayHistory.last?.timestamp,
           point.timestamp < lastTimestamp {
            displayHistory.append(point)
            displayHistory = Self.prunedDisplayHistory(displayHistory, referenceDate: referenceDate)
            return
        }

        displayHistory.append(point)
        displayHistory = Self.prunedSortedDisplayHistory(displayHistory, referenceDate: referenceDate)
    }

    private func shouldPublishDisplayHistory(referenceDate: Date, mode: SamplingMode) -> Bool {
        let interval: TimeInterval
        switch mode {
        case .foreground:
            interval = Self.foregroundDisplayHistoryInterval
        case .background, .menuBar:
            interval = Self.backgroundDisplayHistoryInterval
        }

        return shouldRun(lastDate: lastDisplayHistoryPublishDate, referenceDate: referenceDate, interval: interval)
    }

    private func publishDisplayHistory(referenceDate: Date, force: Bool = false) {
        guard force || shouldPublishDisplayHistory(referenceDate: referenceDate, mode: mode) else {
            return
        }

        var updatedSnapshot = snapshot
        updatedSnapshot.history = displayHistory
        lastDisplayHistoryPublishDate = referenceDate
        publishSnapshotIfChanged(updatedSnapshot)
    }

    private func publishSnapshotIfChanged(_ updatedSnapshot: SystemStatusSnapshot) {
        guard updatedSnapshot != snapshot else {
            return
        }

        snapshot = updatedSnapshot
    }

    static func prunedSortedDisplayHistory(
        _ points: [SystemStatusHistoryPoint], referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        SystemStatusHistoryProcessing.pruned(points, referenceDate: referenceDate, sorted: true)
    }

    static func prunedDisplayHistory(
        _ points: [SystemStatusHistoryPoint], referenceDate: Date
    ) -> [SystemStatusHistoryPoint] {
        SystemStatusHistoryProcessing.pruned(points, referenceDate: referenceDate)
    }

    private static func resolveApplicationNames(for processes: [SystemStatusTopProcess]) async -> [SystemStatusTopProcess] {
        let applications = NSWorkspace.shared.runningApplications
        return processes.map { process in
            let application = applications.first { application in
                if process.applicationID?.hasPrefix("app:") == true {
                    return application.bundleURL?.path == process.command
                }
                return application.processIdentifier == pid_t(process.pid)
            }
            guard let name = application?.localizedName, !name.isEmpty else { return process }
            return process.replacingDisplayName(name)
        }
    }
}

struct SystemStatusComponentView: View {
    private enum Layout {
        static let spacing = SystemStatusComponentLayout.cardSpacing
    }

    let viewModel: SystemStatusViewModel
    @ObservedObject var settingsController: SystemStatusSettingsController
    let localization: PluginLocalization
    let onMetricDetail: (SystemStatusMetricKind) -> Void

    var body: some View {
        PluginObservedContent(viewModel) { _ in
            dashboard
        }
    }

    private var dashboard: some View {
        SystemStatusDashboardView(
            snapshot: viewModel.snapshot,
            visibleKinds: settingsController.configuration.visiblePanelMetricKinds,
            processSort: settingsController.configuration.processSort,
            processLimit: settingsController.configuration.processLimit,
            configuration: settingsController.configuration,
            onProcessSortChange: settingsController.setProcessSort,
            localization: localization,
            onMetricDetail: onMetricDetail
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var compactCPUCard: some View {
        let cpu = viewModel.snapshot.cpu
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.cpu.title(localization: localization),
            percentText: cpu.isCollecting ? "--" : SystemStatusFormatter.percent(cpu.usage),
            detailLines: [
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(cpu.temperatureCelsius)
                ),
                localization.format(
                    "metric.powerFormat",
                    defaultValue: "功率 %@",
                    SystemStatusFormatter.power(cpu.cpuPowerWatts)
                )
            ],
            progress: cpu.usage
        )
    }

    private var compactMemoryCard: some View {
        let memory = viewModel.snapshot.memory
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.memory.title(localization: localization),
            percentText: SystemStatusFormatter.percent(memory.usage),
            detailLines: [
                localization.format(
                    "metric.usedFormat",
                    defaultValue: "已用 %@",
                    SystemStatusFormatter.bytes(memory.usedBytes)
                ),
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(memory.totalBytes)
                )
            ],
            progress: memory.usage
        )
    }

    private var compactDiskCard: some View {
        let disk = viewModel.snapshot.disk
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.disk.title(localization: localization),
            percentText: SystemStatusFormatter.percent(disk.usage),
            detailLines: [
                localization.format(
                    "metric.usedFormat",
                    defaultValue: "已用 %@",
                    SystemStatusFormatter.bytes(disk.usedBytes)
                ),
                localization.format(
                    "metric.totalFormat",
                    defaultValue: "总量 %@",
                    SystemStatusFormatter.bytes(disk.totalBytes)
                )
            ],
            progress: disk.usage
        )
    }

    private var compactBatteryCard: some View {
        let battery = viewModel.snapshot.battery
        return SystemStatusCompactMetricCard(
            title: SystemStatusMetricKind.battery.title(localization: localization),
            percentText: battery.isAvailable ? SystemStatusFormatter.percent(battery.level) : "--",
            detailLines: [
                localization.format(
                    "metric.temperatureFormat",
                    defaultValue: "温度 %@",
                    SystemStatusFormatter.temperature(battery.temperatureCelsius)
                ),
                batteryHealthText(for: battery)
            ],
            progress: battery.level,
            centerSubtext: batteryCircleStatusText(for: battery),
            centerHelpText: batteryShortText(for: battery)
        )
    }

    private var networkCard: some View {
        let network = viewModel.snapshot.network
        return SystemStatusWideInfoCard(
            title: SystemStatusMetricKind.network.title(localization: localization),
            iconName: "wifi",
            tint: Color(nsColor: .systemCyan),
            headerLeadingPadding: 4
        ) {
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 2) {
                    SystemStatusNetworkSpeedRow(
                        iconName: "arrow.down",
                        value: SystemStatusFormatter.speed(network.downloadBytesPerSecond),
                        tint: Color(nsColor: .systemBlue)
                    )
                    SystemStatusNetworkSpeedRow(
                        iconName: "arrow.up",
                        value: SystemStatusFormatter.speed(network.uploadBytesPerSecond),
                        tint: Color(nsColor: .systemGreen)
                    )
                }

                VStack(alignment: .leading, spacing: 1) {
                    SystemStatusKeyValueLine(
                        label: localization.string("network.publicIP", defaultValue: "公网"),
                        value: network.publicIPAddress
                            ?? localization.string("network.publicIP.collecting", defaultValue: "获取中"),
                        copyValue: network.publicIPAddress,
                        localization: localization
                    )
                    SystemStatusKeyValueLine(
                        label: localization.string("network.localIP", defaultValue: "内网"),
                        value: network.ipAddress ?? "—",
                        copyValue: network.ipAddress,
                        localization: localization
                    )
                }
            }
        }
    }

    private var topProcessesCard: some View {
        SystemStatusTopProcessesCard(
            processes: Array(viewModel.snapshot.topProcesses.prefix(3)),
            localization: localization
        )
    }

    private func batteryShortText(for battery: SystemStatusBatterySnapshot) -> String {
        guard battery.isAvailable else {
            return battery.state.title(localization: localization)
        }

        if battery.state == .charged {
            return localization.string("battery.state.charged", defaultValue: "已充满")
        }

        if battery.state == .charging || battery.state == .acPower {
            return battery.state.title(localization: localization)
        }

        return SystemStatusFormatter.timeRemaining(minutes: battery.timeRemainingMinutes, localization: localization)
    }

    private func batteryHealthText(for battery: SystemStatusBatterySnapshot) -> String {
        guard let healthPercent = battery.healthPercent else {
            return localization.string("battery.healthUnavailable", defaultValue: "健康度 —")
        }

        return localization.format("battery.healthFormat", defaultValue: "健康度 %d%%", healthPercent)
    }

    private func batteryCircleStatusText(for battery: SystemStatusBatterySnapshot) -> String? {
        guard battery.isAvailable else {
            return nil
        }

        switch battery.state {
        case .charging, .charged, .acPower, .unplugged:
            return battery.state.title(localization: localization)
        case .unavailable, .unknown:
            return nil
        }
    }
}

private enum SystemStatusCircleStyle {
    static let tint = Color(nsColor: .systemBlue)
}

private struct SystemStatusCompactMetricCard: View {
    let title: String
    let percentText: String
    let detailLines: [String]
    let progress: Double?
    var centerSubtext: String? = nil
    var centerHelpText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                SystemStatusCircularProgress(value: progress, tint: SystemStatusCircleStyle.tint)
                    .frame(width: 58, height: 58)

                VStack(spacing: centerSubtext == nil ? 1 : 0) {
                    Text(title)
                        .font(.system(size: centerSubtext == nil ? 9 : 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(percentText)
                        .font(.system(size: centerSubtext == nil ? 12 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    if let centerSubtext {
                        Text(centerSubtext)
                            .font(.system(size: 6.8, weight: .semibold, design: .rounded))
                            .foregroundStyle(SystemStatusCircleStyle.tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                }
                .padding(.horizontal, 5)
                .help(centerHelpText ?? "")
            }

            Spacer(minLength: 5)

            VStack(spacing: 1) {
                ForEach(Array(detailLines.prefix(2).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 7.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .help(detailLines.joined(separator: "\n"))
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }
}
private struct SystemStatusWideInfoCard<Content: View>: View {
    let title: String
    let iconName: String
    let tint: Color
    var headerLeadingPadding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: PluginSystemImage.resolvedName(iconName))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.leading, headerLeadingPadding)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }
}

private enum SystemStatusNetworkRowLayout {
    static let leadingColumnWidth: CGFloat = 22
    static let columnSpacing: CGFloat = 5
}

private struct SystemStatusNetworkSpeedRow: View {
    let iconName: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: SystemStatusNetworkRowLayout.columnSpacing) {
            Image(systemName: PluginSystemImage.resolvedName(iconName))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: SystemStatusNetworkRowLayout.leadingColumnWidth, alignment: .center)

            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SystemStatusKeyValueLine: View {
    let label: String
    let value: String
    let copyValue: String?
    let localization: PluginLocalization

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SystemStatusNetworkRowLayout.columnSpacing) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: SystemStatusNetworkRowLayout.leadingColumnWidth, alignment: .center)

            Text(value)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                .help(value)
                .layoutPriority(1)

            if canCopy {
                Button(action: copyToPasteboard) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
                .disabled(!isHovering)
                .help(localization.format("network.copyIPHelpFormat", defaultValue: "复制%@ IP", label))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
    }

    private var canCopy: Bool {
        guard let copyValue else {
            return false
        }

        return !copyValue.isEmpty
    }

    private func copyToPasteboard() {
        guard let copyValue, !copyValue.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyValue, forType: .string)
    }
}

private struct SystemStatusTopProcessesCard: View {
    let processes: [SystemStatusTopProcess]
    let localization: PluginLocalization

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if processes.isEmpty {
                Text(localization.string("topProcesses.collecting", defaultValue: "采集中…"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(spacing: 4) {
                    ForEach(processes) { process in
                        SystemStatusProcessRow(process: process)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(SystemStatusComponentLayout.cardContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            PluginComponentCardBackground(
                cornerRadius: SystemStatusComponentLayout.cardCornerRadius
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemPink))
                .frame(width: 14, height: 14)

            Text(SystemStatusMetricKind.topProcesses.title(localization: localization))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            SystemStatusProcessMetricHeader()
                .layoutPriority(1)
        }
    }
}

private struct SystemStatusProcessMetricHeader: View {
    var body: some View {
        HStack(spacing: SystemStatusProcessRow.metricColumnSpacing) {
            Text("CPU")
                .frame(width: SystemStatusProcessRow.cpuColumnWidth, alignment: .trailing)
            Text("MEM")
                .frame(width: SystemStatusProcessRow.memoryColumnWidth, alignment: .trailing)
        }
        .font(.system(size: 7.5, weight: .bold, design: .rounded))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SystemStatusProcessRow: View {
    static let cpuColumnWidth: CGFloat = 28
    static let memoryColumnWidth: CGFloat = 52
    static let metricColumnSpacing: CGFloat = 1

    let process: SystemStatusTopProcess

    var body: some View {
        HStack(spacing: 4) {
            Text(process.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(process.displayName)

            Spacer(minLength: 1)

            HStack(spacing: Self.metricColumnSpacing) {
                metricText(SystemStatusFormatter.wholePercent(process.cpuPercent, fractionDigits: 0))
                    .frame(width: Self.cpuColumnWidth, alignment: .trailing)
                metricText(SystemStatusFormatter.bytes(process.memoryBytes))
                    .frame(width: Self.memoryColumnWidth, alignment: .trailing)
            }
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func metricText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}
private struct SystemStatusCircularProgress: View {
    let value: Double?
    let tint: Color

    @Environment(\.pluginComponentTheme) private var theme

    private var clampedValue: Double {
        min(max(value ?? 0, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.surfaces.track, lineWidth: 4)

            Circle()
                .trim(from: 0, to: clampedValue)
                .stroke(
                    tint.opacity(value == nil ? 0.22 : 0.86),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }
}
