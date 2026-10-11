import AppKit
import Foundation
import MacToolsPluginKit
import OSLog
import SwiftUI

public final class SavedScriptsPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        SavedScriptsPluginProvider(context: context)
    }
}

@MainActor
private struct SavedScriptsPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [SavedScriptsPlugin(context: context)]
    }
}

@MainActor
final class SavedScriptsPlugin:
    MacToolsPlugin, PluginActionProviding, PluginActionExecutionRevisionProviding, PluginSettingsPresenting, PluginSettingsSearchFocusing, PluginPortablePreferencesProviding, PluginPersistentPreferencesChangeSignaling, PluginPortablePreferencesRestorationReporting, PluginPortablePreferencesActionReferencesProviding, PluginActionReferenceBackupProviding {
    var panelItems: [PluginPanelItem] {
        var state = rowState
        state.indicator = rowIndicator
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: rowDescriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
        ]
    }

    private enum ControlID {
        static let openManager = "open-manager"
        static let runPrefix = "run."
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "saved-scripts",
            title: localization.string("metadata.title", defaultValue: "已存脚本"),
            iconName: "terminal.fill",
            iconTint: Color(nsColor: .systemIndigo),
            order: 73,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "保存并运行 AppleScript 和 Shell 脚本"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor
    let store: SavedScriptsStore
    let executionStore = SavedScriptsExecutionStore()

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?
    var onPersistentPreferencesChange: (() -> Void)? {
        get { persistentPreferencesChanges.onChange }
        set { persistentPreferencesChanges.onChange = newValue }
    }

    private let localization: PluginLocalization
    private let runner: any SavedScriptRunning
    private let persistentPreferencesChanges = PluginPersistentPreferencesChangeEmitter()
    private let settingsSearchFocusController = SavedScriptsSettingsSearchFocusController()
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "SavedScriptsPlugin"
    )
    private struct ActiveRun {
        let token: UUID
        let task: Task<ActionExecutionResult, Never>
        let isManual: Bool
    }

    private var isExpanded = false
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var indicatorExpirationTask: Task<Void, Never>?
    private let indicatorNow: () -> Date
    private static let completionIndicatorVisibility: TimeInterval = 8

    var actionExecutionRevision: UInt64 { store.revision }

    init(
        context: PluginRuntimeContext,
        localization: PluginLocalization? = nil,
        runner: (any SavedScriptRunning)? = nil,
        indicatorNow: @escaping () -> Date = { .now }
    ) {
        let localization = localization ?? PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.store = SavedScriptsStore(storage: context.storage)
        self.runner = runner ?? ProcessSavedScriptRunner(
            temporaryDirectory: context.temporaryDirectory ?? FileManager.default.temporaryDirectory
        )
        self.indicatorNow = indicatorNow
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .disclosure,
            menuActionBehavior: .keepPresented
        )
        self.store.onMutation = { [weak self] in
            self?.onStateChange?()
            self?.persistentPreferencesChanges.didPersist()
        }
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(
            description: localization.string(
                "metadata.description",
                defaultValue: "保存并运行 AppleScript 和 Shell 脚本"
            ),
            scrolling: .host
        ) { [weak self] _ in
            if let self {
                SavedScriptsSettingsView(
                    plugin: self,
                    searchFocusController: self.settingsSearchFocusController
                )
            } else {
                EmptyView()
            }
        }
    }

    func focusSettingsSearch() {
        settingsSearchFocusController.requestFocus()
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: panelSubtitle,
            isOn: false,
            isEnabled: true,
            isAvailable: true,
            detail: isExpanded ? panelDetail : nil,
            errorMessage: store.loadError.map { error in
                error == "invalid-saved-scripts-library"
                    ? localization.string(
                        "settings.library.invalid",
                        defaultValue: "无法读取脚本库；原始数据已保留。"
                    )
                    : error
            }
        )
    }

    var rowIndicator: PluginPanelRowIndicator? {
        guard let record = executionStore.mostRecentRecord else { return nil }
        switch record.status {
        case .running:
            return PluginPanelRowIndicator(
                text: localization.string("run.status.running", defaultValue: "运行中"),
                systemImage: "progress.indicator"
            )
        case .succeeded:
            guard showsCompletedIndicator(record) else { return nil }
            return PluginPanelRowIndicator(
                text: localization.string("run.status.succeeded", defaultValue: "已完成"),
                systemImage: "checkmark.circle.fill"
            )
        case .failed:
            guard showsCompletedIndicator(record) else { return nil }
            return PluginPanelRowIndicator(
                text: localization.string("run.status.failed", defaultValue: "失败"),
                systemImage: "exclamationmark.triangle.fill"
            )
        case .cancelled:
            guard showsCompletedIndicator(record) else { return nil }
            return PluginPanelRowIndicator(
                text: localization.string("run.status.cancelled", defaultValue: "已取消"),
                systemImage: "xmark.circle.fill"
            )
        }
    }

    var actionDefinitions: [ActionDefinition] {
        store.scripts.map { script in
            let needsConfirmationCopy = script.confirmOutsideManager
                || script.allowExternalInvocation
            var capabilities: ActionExecutionCapabilities = [
                .background,
                .foregroundInteractive,
                .cancellable,
                .reportsProgress,
            ]
            if !script.confirmOutsideManager {
                capabilities.insert(.automatic)
            }
            return ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: script.actionID),
                title: script.name,
                description: localization.format(
                    "action.description.format",
                    defaultValue: "运行已存的 %@ 脚本。",
                    kindTitle(script.kind)
                ),
                keywords: [
                    metadata.title,
                    script.name,
                    kindTitle(script.kind),
                    "script",
                    "shell",
                    "AppleScript",
                ],
                systemImage: script.kind.systemImage,
                risk: script.confirmOutsideManager ? .confirmationRequired : .safe,
                // Local action surfaces use `risk` to decide whether to confirm. Run Links use
                // `externalInvocationPolicy`, but still need this copy even when local
                // confirmation is disabled.
                confirmation: needsConfirmationCopy
                    ? ActionConfirmation(
                        title: localization.format(
                            "action.confirm.title.format",
                            defaultValue: "运行“%@”？",
                            script.name
                        ),
                        message: localization.string(
                            "action.confirm.message",
                            defaultValue: "脚本将以你的用户权限运行，并可访问你的文件和应用。"
                        ),
                        confirmButtonTitle: localization.string(
                            "action.confirm.button",
                            defaultValue: "运行"
                        )
                    )
                    : nil,
                externalInvocationPolicy: script.allowExternalInvocation ? .confirmAlways : .unavailable,
                capabilities: capabilities,
                executionTimeoutSeconds: Double(script.timeoutSeconds)
                    + ProcessSavedScriptRunner.actionExecutionTimeoutGraceSeconds
            )
        }
    }

    var actionCatalogEntries: [ActionCatalogEntry] {
        store.scripts.map { script in
            ActionCatalogEntry(
                reference: ActionReference(
                    key: ActionKey(providerID: metadata.id, actionID: script.actionID)
                ),
                title: script.name,
                subtitle: kindTitle(script.kind)
            )
        }
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard let script = script(for: reference) else {
            return .unavailable(localization.string(
                "action.unavailable.missing",
                defaultValue: "找不到已存脚本。"
            ))
        }
        guard !executionStore.isRunning(script.id) else {
            return .unavailable(localization.string(
                "action.unavailable.running",
                defaultValue: "脚本正在运行。"
            ))
        }
        guard FileManager.default.isExecutableFile(atPath: script.kind.executableURL.path) else {
            return .unavailable(localization.string(
                "action.unavailable.interpreter",
                defaultValue: "脚本解释器不可用。"
            ))
        }
        if !script.workingDirectory.isEmpty {
            let path = (script.workingDirectory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .unavailable(localization.string(
                    "action.unavailable.workingDirectory",
                    defaultValue: "工作目录不存在。"
                ))
            }
        }
        return .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard let script = script(for: invocation.reference) else {
            return ActionExecutionHandle {
                .failed(message: self.localization.string(
                    "action.unavailable.missing",
                    defaultValue: "找不到已存脚本。"
                ))
            }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            guard let run = self.startExecution(script, isManual: false) else {
                return .failed(message: self.localization.string(
                    "action.unavailable.running",
                    defaultValue: "脚本正在运行。"
                ))
            }
            return await self.waitForExecution(run, scriptID: script.id)
        } cancel: { [weak self] in
            self?.cancelExecution(scriptID: script.id)
        }
    }

    func deactivate(reason _: PluginDeactivationReason) {
        indicatorExpirationTask?.cancel()
        indicatorExpirationTask = nil
        let runs = Array(activeRuns.values)
        activeRuns.removeAll()
        runs.forEach { $0.task.cancel() }
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case let .setDisclosureExpanded(expanded):
            isExpanded = expanded
            onStateChange?()
        case let .invokeAction(controlID):
            if controlID == ControlID.openManager {
                requestSettingsPresentation?()
            } else if let scriptID = scriptID(from: controlID) {
                runManual(scriptID: scriptID)
            }
        case .setSwitch, .setSelection, .setNavigationSelection,
             .clearNavigationSelection, .setDate, .setSlider:
            break
        }
    }

    func runManual(scriptID: UUID) {
        guard let script = store.script(id: scriptID),
              let run = startExecution(script, isManual: true) else { return }
        Task { @MainActor [weak self] in
            _ = await self?.waitForExecution(run, scriptID: scriptID)
        }
    }

    func cancelExecution(scriptID: UUID) {
        activeRuns[scriptID]?.task.cancel()
    }

    func saveScript(_ candidate: SavedScript) -> Result<SavedScript, Error> {
        let previousScripts = scriptsByID
        let result = store.save(candidate)
        guard case .success = result else { return result }
        reconcileActiveRuns(from: previousScripts)
        return result
    }

    func deleteScript(id: UUID) -> Bool {
        let previousScripts = scriptsByID
        guard store.remove(id: id) else { return false }
        reconcileActiveRuns(from: previousScripts)
        executionStore.removeRecord(for: id)
        return true
    }

    func isManualRun(_ scriptID: UUID) -> Bool {
        activeRuns[scriptID]?.isManual == true
    }

    func makePortablePreferencesBackup() -> Data? {
        store.portableBackup()
    }

    func restorePortablePreferences(from data: Data) {
        _ = restorePortablePreferencesAndCancelChangedRuns(from: data)
    }

    func restorePortablePreferencesReportingResult(from data: Data) -> Bool {
        restorePortablePreferencesAndCancelChangedRuns(from: data)
    }

    func actionReferences(inPortablePreferences data: Data) -> [ActionReference]? {
        store.actionIDs(inPortableBackup: data)?.map {
            ActionReference(key: ActionKey(providerID: metadata.id, actionID: $0))
        }
    }

    func backupDisposition(
        for reference: ActionReference
    ) -> PluginActionReferenceBackupDisposition {
        guard let script = script(for: reference) else { return .excluded }
        return script.includeSourceInBackup ? .requiresPluginPreferences : .excluded
    }

    func kindTitle(_ kind: SavedScriptKind) -> String {
        switch kind {
        case .appleScript:
            localization.string("kind.appleScript", defaultValue: "AppleScript")
        case .zsh:
            localization.string("kind.zsh", defaultValue: "zsh")
        case .bash:
            localization.string("kind.bash", defaultValue: "Bash")
        case .sh:
            localization.string("kind.sh", defaultValue: "Shell")
        }
    }

    func statusTitle(_ status: SavedScriptRunStatus) -> String {
        switch status {
        case .running: localization.string("run.status.running", defaultValue: "运行中")
        case .succeeded: localization.string("run.status.succeeded", defaultValue: "已完成")
        case .failed: localization.string("run.status.failed", defaultValue: "失败")
        case .cancelled: localization.string("run.status.cancelled", defaultValue: "已取消")
        }
    }

    func localized(_ key: String, defaultValue: String) -> String {
        localization.string(key, defaultValue: defaultValue)
    }

    func localizedFormat(_ key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
        String(
            format: localization.string(key, defaultValue: defaultValue),
            locale: PluginRuntimeLocalization.locale,
            arguments: arguments
        )
    }

    private func execute(_ script: SavedScript) async -> ActionExecutionResult {
        guard !executionStore.isRunning(script.id) else {
            return .failed(message: localization.string(
                "action.unavailable.running",
                defaultValue: "脚本正在运行。"
            ))
        }
        let runID = executionStore.begin(script)
        indicatorExpirationTask?.cancel()
        onStateChange?()
        do {
            let result = try await runner.run(script)
            if result.exitCode == 0 {
                let message = result.standardOutput
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                executionStore.finish(
                    scriptID: script.id,
                    runID: runID,
                    status: .succeeded,
                    result: result,
                    message: message
                )
                executionDidFinish()
                return .succeeded(message: message.map(Self.actionMessage))
            }
            let message = result.standardError
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? localization.format(
                    "run.error.exitCode.format",
                    defaultValue: "脚本退出，状态码 %d。",
                    result.exitCode
                )
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .failed,
                result: result,
                message: message
            )
            executionDidFinish()
            return .failed(message: Self.actionMessage(message))
        } catch is CancellationError {
            let message = localization.string("run.error.cancelled", defaultValue: "脚本已取消。")
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .cancelled,
                message: message
            )
            executionDidFinish()
            return .cancelled
        } catch SavedScriptProcessError.timedOut {
            let message = localization.format(
                "run.error.timeout.format",
                defaultValue: "脚本运行超过 %d 秒，已停止。",
                script.timeoutSeconds
            )
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .failed,
                message: message
            )
            executionDidFinish()
            return .failed(message: message)
        } catch SavedScriptProcessError.invalidWorkingDirectory {
            let message = localization.string(
                "run.error.workingDirectory",
                defaultValue: "工作目录不存在。"
            )
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .failed,
                message: message
            )
            executionDidFinish()
            return .failed(message: message)
        } catch SavedScriptProcessError.executableUnavailable {
            let message = localization.string(
                "run.error.interpreter",
                defaultValue: "脚本解释器不可用。"
            )
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .failed,
                message: message
            )
            executionDidFinish()
            return .failed(message: message)
        } catch {
            let message = error.localizedDescription
            executionStore.finish(
                scriptID: script.id,
                runID: runID,
                status: .failed,
                message: message
            )
            executionDidFinish()
            logger.error("Saved script failed: \(message, privacy: .private)")
            return .failed(message: message)
        }
    }

    private func startExecution(_ script: SavedScript, isManual: Bool) -> ActiveRun? {
        guard activeRuns[script.id] == nil,
              !executionStore.isRunning(script.id) else {
            return nil
        }
        let token = UUID()
        let task = Task<ActionExecutionResult, Never> { @MainActor [weak self] in
            guard let self else { return ActionExecutionResult.cancelled }
            return await self.execute(script)
        }
        let run = ActiveRun(token: token, task: task, isManual: isManual)
        activeRuns[script.id] = run
        return run
    }

    private func restorePortablePreferencesAndCancelChangedRuns(from data: Data) -> Bool {
        let previousScripts = scriptsByID
        guard store.restorePortableBackup(data) else { return false }
        reconcileActiveRuns(from: previousScripts)
        return true
    }

    private var scriptsByID: [UUID: SavedScript] {
        Dictionary(uniqueKeysWithValues: store.scripts.map { ($0.id, $0) })
    }

    private func reconcileActiveRuns(from previousScripts: [UUID: SavedScript]) {
        for (scriptID, run) in activeRuns
        where store.script(id: scriptID) != previousScripts[scriptID] {
            run.task.cancel()
        }
    }

    private func waitForExecution(
        _ run: ActiveRun,
        scriptID: UUID
    ) async -> ActionExecutionResult {
        let result = await withTaskCancellationHandler {
            await run.task.value
        } onCancel: {
            run.task.cancel()
        }
        if activeRuns[scriptID]?.token == run.token {
            activeRuns[scriptID] = nil
        }
        return result
    }

    private func showsCompletedIndicator(_ record: SavedScriptRunRecord) -> Bool {
        guard let finishedAt = record.finishedAt else { return false }
        return indicatorNow().timeIntervalSince(finishedAt) < Self.completionIndicatorVisibility
    }

    private func executionDidFinish() {
        onStateChange?()
        indicatorExpirationTask?.cancel()
        indicatorExpirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.completionIndicatorVisibility))
            } catch {
                return
            }
            self?.onStateChange?()
        }
    }

    private var panelSubtitle: String {
        if let running = store.scripts.first(where: { executionStore.isRunning($0.id) }) {
            return localization.format(
                "panel.subtitle.running.format",
                defaultValue: "正在运行：%@",
                running.name
            )
        }
        return localization.format(
            "panel.subtitle.count.format",
            defaultValue: "%d 个已存脚本",
            store.scripts.count
        )
    }

    private var panelDetail: PluginPanelDetail {
        let scriptControls = store.scripts.prefix(8).map { script in
            PluginPanelControl(
                id: script.actionID,
                kind: .actionRow,
                options: [],
                selectedOptionID: nil,
                dateValue: nil,
                minimumDate: nil,
                displayedComponents: nil,
                datePickerStyle: nil,
                sectionTitle: nil,
                actionTitle: executionStore.isRunning(script.id)
                    ? localization.format(
                        "panel.action.running.format",
                        defaultValue: "正在运行“%@”…",
                        script.name
                    )
                    : script.name,
                actionIconSystemName: executionStore.isRunning(script.id)
                    ? "progress.indicator"
                    : script.kind.systemImage,
                isEnabled: !executionStore.isRunning(script.id)
            )
        }
        let openManager = PluginPanelControl(
            id: ControlID.openManager,
            kind: .actionRow,
            options: [],
            selectedOptionID: nil,
            dateValue: nil,
            minimumDate: nil,
            displayedComponents: nil,
            datePickerStyle: nil,
            sectionTitle: nil,
            actionTitle: localization.string(
                "panel.action.openManager",
                defaultValue: "管理脚本…"
            ),
            actionIconSystemName: "slider.horizontal.3",
            actionBehavior: .dismissBeforeHandling,
            showsLeadingDivider: !scriptControls.isEmpty,
            isEnabled: true
        )
        return PluginPanelDetail(primaryControls: scriptControls + [openManager], secondaryPanel: nil)
    }

    private func script(for reference: ActionReference) -> SavedScript? {
        guard reference.key.providerID == metadata.id,
              reference.parameters == .empty,
              let id = scriptID(from: reference.key.actionID) else { return nil }
        return store.script(id: id)
    }

    private func scriptID(from actionID: String) -> UUID? {
        guard actionID.hasPrefix(ControlID.runPrefix) else { return nil }
        return UUID(uuidString: String(actionID.dropFirst(ControlID.runPrefix.count)))
    }

    private static func actionMessage(_ message: String) -> String {
        String(message.prefix(500))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
