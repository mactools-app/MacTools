import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import MacToolsPluginKit

// MARK: - Factory

public final class FixDamagedAppPluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(context: PluginRuntimeContext) throws -> any PluginProvider {
        FixDamagedAppPluginProvider(context: context)
    }
}

@MainActor
private struct FixDamagedAppPluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [FixDamagedAppPlugin(context: context)]
    }
}

// MARK: - Plugin

@MainActor
final class FixDamagedAppPlugin: MacToolsPlugin, DropZoneAnchorProviding, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("metadata.title", defaultValue: metadata.title),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    private enum ActionID {
        static let chooseApp = "choose-app"
    }

    // MARK: Metadata

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "fix-damaged-app",
            title: localization.string("metadata.title", defaultValue: "修复损坏应用"),
            iconName: "wrench.and.screwdriver.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 94,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "移除隔离属性，解决「已损坏」或「不受信任」提示"
            )
        )
    }

    // MARK: State

    private enum FixState: Equatable {
        case idle
        case running
        case success(appName: String)
        case failure(message: String)
    }

    private var selectedApp: URL?
    private var fixState: FixState = .idle

    // MARK: Drag Detection State

    private let storage: PluginStorage
    private var mouseDownMonitor: Any?
    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var dropZonePanel: FixDamagedAppDropZonePanel?
    private var isDragPanelShowing = false
    private var isMouseButtonDown = false
    /// Drag pasteboard change count captured at mouseDown to identify a new drag session.
    private var dragSessionPasteboardChangeCount: Int = Int.min
    private let localization: PluginLocalization
    private let appChooser: () -> URL?
    private let quarantineRemover: (String) async throws -> Void

    // MARK: DropZoneAnchorProviding

    var anchorRectProvider: (() -> NSRect?)?

    var isDragDetectionEnabled: Bool {
        storage.bool(forKey: StorageKey.isDragDetectionEnabled)
    }

    // MARK: Storage Keys

    private enum StorageKey {
        static let isDragDetectionEnabled = "drag-detection-enabled"
    }

    // MARK: MacToolsPlugin

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
        category: "FixDamagedAppPlugin"
    )

    var permissionRequirements: [PluginPermissionRequirement] { [] }
    var shortcutDefinitions: [PluginShortcutDefinition] { [] }

    var actionDefinitions: [ActionDefinition] {
        [
            ActionDefinition(
                key: ActionKey(providerID: metadata.id, actionID: ActionID.chooseApp),
                title: metadata.title,
                description: metadata.defaultDescription,
                keywords: [metadata.title, metadata.defaultDescription, "app", "quarantine"],
                systemImage: metadata.iconName,
                externalInvocationPolicy: .unavailable,
                capabilities: [.foregroundInteractive]
            ),
        ]
    }

    // MARK: Init

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "fix-damaged-app"),
        appChooser: (() -> URL?)? = nil,
        quarantineRemover: ((String) async throws -> Void)? = nil
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.appChooser = appChooser ?? {
            Self.chooseApplication(localization: localization)
        }
        self.quarantineRemover = quarantineRemover ?? { appPath in
            try await runQuarantineRemoval(appPath: appPath, localization: localization)
        }
        self.storage = context.storage
        self.rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: { localization.string("panel.button.choose", defaultValue: "选择") }
        )
    }

    // MARK: Lifecycle

    func activate(context: PluginRuntimeContext) {
        updateDragMonitoring()
    }

    func deactivate(reason: PluginDeactivationReason) {
        stopDragMonitoring()
        hideDropZonePanel()
    }

    func refresh() {}

    // MARK: Configuration

    var settingsPage: PluginSettingsPage? {
        .form(
            description: metadata.defaultDescription,
            sections: [
                PluginSettingsSection(
                    id: "behavior",
                    title: localization.string("settings.section.behavior", defaultValue: "行为"),
                    systemImage: "hand.rays",
                    rows: [
                        PluginSettingsRow(
                            id: "drag-detection",
                            title: localization.string("settings.dragDetection.title", defaultValue: "拖动检测"),
                            description: localization.string(
                                "settings.dragDetection.description",
                                defaultValue: "拖入 .app 文件后松手，自动弹出修复窗口并开始修复。"
                            ),
                            systemImage: "hand.draw",
                            control: .toggle(isOn: isDragDetectionEnabled)
                        )
                    ]
                )
            ]
        )
    }

    func handleSettingsAction(_ action: PluginSettingsAction) {
        guard case let .setBoolean(controlID, isOn) = action,
              controlID == "drag-detection"
        else { return }
        setDragDetectionEnabled(isOn)
    }

    func setDragDetectionEnabled(_ enabled: Bool) {
        storage.set(enabled, forKey: StorageKey.isDragDetectionEnabled)
        updateDragMonitoring()
        onStateChange?()
    }

    // MARK: - Panel row

    let rowDescriptor: PluginPanelRowDescriptor

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: primarySubtitle,
            isOn: false,
            isEnabled: fixState != .running,
            isAvailable: true,
            detail: nil,
            errorMessage: primaryError
        )
    }

    func handleAction(_ action: PluginPanelAction) {
        switch action {
        case .invokeAction(let controlID):
            handleControlAction(controlID: controlID)
        default:
            break
        }
    }

    func permissionState(for permissionID: String) -> PluginPermissionState {
        PluginPermissionState(isGranted: true, footnote: nil)
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key.actionID == ActionID.chooseApp else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return fixState == .running
            ? .unavailable(localization.string("panel.subtitle.running", defaultValue: "修复中…"))
            : .available
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        guard invocation.reference.key.actionID == ActionID.chooseApp else {
            return ActionExecutionHandle { .failed(message: PluginKitLocalization.actionInvalidParameters) }
        }
        return ActionExecutionHandle { [weak self] in
            guard let self else { return .cancelled }
            return await self.chooseAndRepairApp()
        }
    }

    // MARK: Private

    private func handleControlAction(controlID: String) {
        switch controlID {
        case "execute":
            Task { [weak self] in
                _ = await self?.chooseAndRepairApp()
            }
        default:
            break
        }
    }

    private var primarySubtitle: String {
        switch fixState {
        case .idle:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent }
                ?? localization.string("panel.subtitle.chooseApp", defaultValue: "选择 .app 文件以修复")
        case .running:
            return localization.string("panel.subtitle.running", defaultValue: "修复中…")
        case .success(let name):
            return localization.format("panel.subtitle.successFormat", defaultValue: "已修复：%@", name)
        case .failure:
            return selectedApp.map { $0.deletingPathExtension().lastPathComponent }
                ?? localization.string("panel.subtitle.chooseApp", defaultValue: "选择 .app 文件以修复")
        }
    }

    private var primaryError: String? {
        guard case .failure(let message) = fixState else { return nil }
        return message
    }

    private static func chooseApplication(localization: PluginLocalization) -> URL? {
        let panel = NSOpenPanel()
        panel.title = localization.string("openPanel.title", defaultValue: "选择要修复的应用")
        panel.message = localization.string("openPanel.message", defaultValue: "选择显示「已损坏」或「不受信任」的应用")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let appBundleType = UTType("com.apple.application-bundle") {
            panel.allowedContentTypes = [appBundleType]
        }
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        PluginPresentationSafety.prepareForWindowOrdering()
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }

    private func chooseAndRepairApp() async -> ActionExecutionResult {
        guard fixState != .running else {
            return .failed(
                message: localization.string("panel.subtitle.running", defaultValue: "修复中…")
            )
        }
        guard let appURL = appChooser() else { return .cancelled }

        selectedApp = appURL
        let appPath = appURL.path
        let appName = appURL.deletingPathExtension().lastPathComponent
        fixState = .running
        onStateChange?()

        do {
            try await quarantineRemover(appPath)
            guard !Task.isCancelled else {
                fixState = .idle
                onStateChange?()
                return .cancelled
            }
            fixState = .success(appName: appName)
            onStateChange?()
            return .succeeded()
        } catch {
            if error is CancellationError || (error as NSError).code == -128 {
                fixState = .idle
                onStateChange?()
                return .cancelled
            }
            let message = error.localizedDescription
            logger.error("Quarantine removal failed for '\(appPath)': \(message)")
            fixState = .failure(message: message)
            onStateChange?()
            return .failed(message: message)
        }
    }

    // MARK: Private - Drag Monitoring

    private func updateDragMonitoring() {
        stopDragMonitoring()
        guard isDragDetectionEnabled else { return }
        startDragMonitoring()
    }

    private func startDragMonitoring() {
        // Global NSEvent monitor callbacks are foreign to Swift concurrency even when AppKit
        // happens to invoke them on the main thread. Deliver them through the main queue instead
        // of asserting MainActor isolation from the callback.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isMouseButtonDown = true
                // Capture the current drag pasteboard version; only a later changeCount indicates
                // that a real drag started.
                self?.dragSessionPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleGlobalDrag()
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isMouseButtonDown = false
                self?.handleGlobalMouseUp()
            }
        }
    }

    private func stopDragMonitoring() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        isMouseButtonDown = false
    }

    private func handleGlobalDrag() {
        guard !isDragPanelShowing, isMouseButtonDown else { return }
        let pb = NSPasteboard(name: .drag)
        // React only after the drag pasteboard changes during this mouse-down cycle. This prevents
        // stale drag pasteboard data from showing the panel on normal clicks, such as opening Finder.
        guard pb.changeCount != dragSessionPasteboardChangeCount else { return }
        guard
            let urls = pb.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL],
            urls.contains(where: { $0.pathExtension.lowercased() == "app" })
        else { return }
        showDropZonePanel()
    }

    private func handleGlobalMouseUp() {
        guard isDragPanelShowing else { return }
        // If the pointer is inside the panel, the file was dropped into the window and the drop
        // pipeline owns dismissal. The global mouseUp arrives before SwiftUI `onDrop`, so it cannot
        // rely on `isDropPending` having been set yet.
        if let panel = dropZonePanel, panel.frame.contains(NSEvent.mouseLocation) { return }
        dropZonePanel?.dismissIfIdle()
    }

    private func showDropZonePanel() {
        isDragPanelShowing = true
        let vm = DropZoneViewModel(
            localization: localization,
            onComplete: { [weak self] appName, succeeded, errorMessage in
                guard let self else { return }
                if succeeded {
                    self.fixState = .success(appName: appName)
                } else {
                    self.fixState = .failure(
                        message: errorMessage
                            ?? self.localization.string("error.fixFailed", defaultValue: "修复失败")
                    )
                }
                self.onStateChange?()
            },
            onDismiss: { [weak self] in
                self?.hideDropZonePanel()
            }
        )
        let panel = FixDamagedAppDropZonePanel(viewModel: vm, localization: localization)
        positionDropZonePanel(panel)
        PluginPresentationSafety.prepareForWindowOrdering(panel)
        panel.makeKeyAndOrderFront(nil)
        dropZonePanel = panel
    }

    private func hideDropZonePanel() {
        dropZonePanel?.orderOut(nil)
        dropZonePanel = nil
        isDragPanelShowing = false
    }

    private func positionDropZonePanel(_ panel: NSPanel) {
        let panelSize = panel.frame.size

        if let anchorRect = anchorRectProvider?() {
            let screenMaxX = NSScreen.main?.frame.maxX ?? 1440
            let rawX = anchorRect.midX - panelSize.width / 2
            let x = max(8, min(rawX, screenMaxX - panelSize.width - 8))
            let y = anchorRect.minY - panelSize.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main else { return }
        let menuBarThickness = NSStatusBar.system.thickness
        let x = screen.frame.midX - panelSize.width / 2
        let y = screen.frame.maxY - menuBarThickness - panelSize.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Quarantine Removal (nonisolated helper)

func runQuarantineRemoval(appPath: String) async throws {
    try await runQuarantineRemoval(
        appPath: appPath,
        localization: PluginLocalization(bundle: .main)
    )
}

func runQuarantineRemoval(appPath: String, localization: PluginLocalization) async throws {
    // Reject paths containing double-quote to prevent AppleScript string literal injection
    guard !appPath.contains("\"") else {
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: localization.string(
                    "error.unsupportedPathCharacters",
                    defaultValue: "应用路径包含不支持的字符（双引号）"
                )
            ]
        )
    }
    // Use AppleScript's `quoted form of` to safely quote the path in the shell command
    let script = """
    set appPath to "\(appPath)"
    do shell script "xattr -r -d com.apple.quarantine " & quoted form of appPath with administrator privileges
    """
    let result = try await FixDamagedAppProcessExecution(
        executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
        arguments: ["-e", script]
    ).run()
    guard result.exitCode == 0 else {
        let errMsg = String(data: result.standardError, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if errMsg.contains("-128") || errMsg.contains("User canceled") {
            throw NSError(
                domain: "FixDamagedAppPlugin",
                code: -128,
                userInfo: [
                    NSLocalizedDescriptionKey: localization.string(
                        "error.userCancelledAuthorization",
                        defaultValue: "用户取消了授权"
                    )
                ]
            )
        }
        throw NSError(
            domain: "FixDamagedAppPlugin",
            code: Int(result.exitCode),
            userInfo: [
                NSLocalizedDescriptionKey: errMsg.isEmpty
                    ? localization.string("error.fixFailedUnknown", defaultValue: "修复失败（未知错误）")
                    : errMsg
            ]
        )
    }
}

struct FixDamagedAppProcessResult: Sendable {
    let exitCode: Int32
    let standardError: Data
}

final class FixDamagedAppProcessExecution: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let lock = NSLock()
    private var processLease: PluginProcessGroupLease?
    private var cancellationRequested = false

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func run() async throws -> FixDamagedAppProcessResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    do {
                        continuation.resume(returning: try runBlocking())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [self] in
            cancel()
        }
    }

    func cancel() {
        let lease = lock.withLock { () -> PluginProcessGroupLease? in
            cancellationRequested = true
            return processLease
        }
        guard let lease else { return }
        lease.signal(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.forceKillIfStillRunning(lease)
        }
    }

    private func runBlocking() throws -> FixDamagedAppProcessResult {
        var errorPipe: [Int32] = [-1, -1]
        guard pipe(&errorPipe) == 0 else { throw POSIXError(.EIO) }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(errorPipe[0])
            close(errorPipe[1])
            throw POSIXError(.EIO)
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        guard posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[1]) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            close(errorPipe[0])
            close(errorPipe[1])
            throw POSIXError(.EIO)
        }

        var pid: pid_t = 0
        let spawnArguments = [executableURL.path] + arguments
        let spawnResult = withFixDamagedCStringArray(spawnArguments) { argv in
            posix_spawn(
                &pid,
                executableURL.path,
                &actions,
                &attributes,
                argv,
                environ
            )
        }
        guard spawnResult == 0 else {
            close(errorPipe[0])
            close(errorPipe[1])
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }
        close(errorPipe[1])

        let reader = FixDamagedAppPipeReader(descriptor: errorPipe[0])
        reader.start()
        let lease = PluginProcessGroupLease(processID: pid)
        let shouldCancel = lock.withLock { () -> Bool in
            processLease = lease
            return cancellationRequested
        }
        if shouldCancel {
            lease.signal(SIGTERM)
        }

        let observedExit = lease.waitForLeaderExit()
        if observedExit {
            lease.signal(SIGTERM)
            usleep(100_000)
            lease.signal(SIGKILL)
        }
        let status = lease.reapLeader()
        let errorData = reader.waitForData()
        let wasCancelled = lock.withLock { () -> Bool in
            if processLease === lease {
                processLease = nil
            }
            return cancellationRequested
        }
        if wasCancelled { throw CancellationError() }
        guard observedExit, let status else {
            throw POSIXError(.ECHILD)
        }
        return FixDamagedAppProcessResult(
            exitCode: Self.exitCode(from: status),
            standardError: errorData
        )
    }

    private func forceKillIfStillRunning(_ lease: PluginProcessGroupLease) {
        let isCurrent = lock.withLock { processLease === lease }
        if isCurrent { lease.signal(SIGKILL) }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}

private final class FixDamagedAppPipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "mactools.fix-damaged-app.stderr")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var data = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func start() {
        queue.async { [self] in
            var collected = Data()
            var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    collected.append(contentsOf: bytes.prefix(count))
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            close(descriptor)
            lock.withLock { data = collected }
            semaphore.signal()
        }
    }

    func waitForData() -> Data {
        semaphore.wait()
        return lock.withLock { data }
    }
}

private func withFixDamagedCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    var mutablePointers = pointers + [nil]
    return mutablePointers.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!)
    }
}
