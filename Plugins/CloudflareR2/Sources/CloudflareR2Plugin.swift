import AppKit
import Foundation
import MacToolsPluginKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol R2ClipboardWriting: AnyObject {
    func copy(_ value: String)
}

@MainActor
final class R2SystemClipboardWriter: R2ClipboardWriting {
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
protocol R2UploadCompletionNotifying: AnyObject {
    func notify(fileName: String, result: R2UploadResult) -> Bool
}

@MainActor
final class R2SystemUploadCompletionNotifier: R2UploadCompletionNotifying {
    private let localization: PluginLocalization

    init(localization: PluginLocalization) {
        self.localization = localization
    }

    func notify(fileName: String, result: R2UploadResult) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = localization.string(
            "completion.title",
            defaultValue: "R2 上传完成"
        )
        alert.informativeText = localization.format(
            "completion.message",
            defaultValue: "%@ 已上传到 R2。",
            fileName
        )
        if result.url != nil {
            alert.addButton(withTitle: localization.string(
                "completion.copyLink",
                defaultValue: "复制链接"
            ))
        }
        alert.addButton(withTitle: localization.string(
            "common.ok",
            defaultValue: "好的"
        ))
        PluginPresentationSafety.prepareForWindowOrdering()
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return result.url != nil && response == .alertFirstButtonReturn
    }
}

final class R2ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Double) -> Void
    private var lastPercentage = 0

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ progress: Double) {
        let clamped = min(1, max(0, progress))
        let percentage = Int(clamped * 100)
        let shouldReport = lock.withLock {
            guard percentage > lastPercentage else { return false }
            lastPercentage = percentage
            return true
        }
        guard shouldReport else { return }
        handler(Double(percentage) / 100)
    }
}

public final class CloudflareR2PluginFactory: NSObject, MacToolsPluginBundleFactory {
    public static func makeProvider(
        context: PluginRuntimeContext
    ) throws -> any PluginProvider {
        CloudflareR2PluginProvider(context: context)
    }
}

@MainActor
private struct CloudflareR2PluginProvider: PluginProvider {
    let context: PluginRuntimeContext

    func makePlugins() -> [any MacToolsPlugin] {
        [CloudflareR2Plugin(context: context)]
    }
}

@MainActor
final class CloudflareR2Plugin: ObservableObject, MacToolsPlugin, PluginSettingsPresenting, PluginActionProviding {
    var panelItems: [PluginPanelItem] {
        let state = rowState
        let descriptor = rowDescriptor
        return [
            .row(id: "control", initialPlacement: .featurePanel,
                 descriptor: descriptor, state: state,
                 action: { [weak self] in self?.handleAction($0) }),
            .iconWidget(
                id: "quick-control",
                title: localization.string("widget.title", defaultValue: "R2 上传"),
                systemImage: metadata.iconName,
                control: .button,
                state: state,
                menuActionBehavior: descriptor.menuActionBehavior,
                action: { [weak self] in self?.handleAction($0) }
            ),
        ]
    }

    enum ControlID {
        static let upload = "execute"
    }

    enum ShortcutID {
        static let upload = "upload-file"
    }

    enum ActionID {
        static let upload = "upload-file"
    }

    var metadata: PluginMetadata {
        PluginMetadata(
            id: "cloudflare-r2",
            title: localization.string(
                "metadata.title",
                defaultValue: "Cloudflare R2 上传"
            ),
            iconName: "icloud.and.arrow.up.fill",
            iconTint: Color(nsColor: .systemOrange),
            order: 75,
            defaultDescription: localization.string(
                "metadata.description",
                defaultValue: "上传文件到 Cloudflare R2"
            )
        )
    }
    let rowDescriptor: PluginPanelRowDescriptor
    let configurationStore: R2ConfigurationStore
    @Published private(set) var status = R2UploadStatus.idle

    var onStateChange: (() -> Void)?
    var requestPermissionGuidance: ((String) -> Void)?
    var shortcutBindingResolver: ((String) -> ShortcutBinding?)?
    var requestSettingsPresentation: (() -> Void)?

    private let uploader: R2Uploading
    private let objectChecker: R2ObjectChecking
    private let filePicker: @MainActor @Sendable () -> URL?
    private let clipboard: any R2ClipboardWriting
    private let completionNotifier: any R2UploadCompletionNotifying
    private let progressPresenter: any R2UploadProgressPresenting
    private let localization: PluginLocalization
    private let logger: Logger
    private let terminalStatusDuration: Duration?
    private var uploadTask: Task<R2UploadResult, Error>?
    private var statusResetTask: Task<Void, Never>?
    private var uploadGeneration: UInt64 = 0

    init(
        context: PluginRuntimeContext = PluginRuntimeContext(pluginID: "cloudflare-r2"),
        uploader: R2Uploading = R2UploadService(),
        objectChecker: R2ObjectChecking = R2UploadService(),
        configurationStore: R2ConfigurationStore? = nil,
        filePicker: (@MainActor @Sendable () -> URL?)? = nil,
        clipboard: (any R2ClipboardWriting)? = nil,
        completionNotifier: (any R2UploadCompletionNotifying)? = nil,
        progressPresenter: (any R2UploadProgressPresenting)? = nil,
        logger: Logger? = nil,
        terminalStatusDuration: Duration? = .seconds(5)
    ) {
        let localization = PluginLocalization(bundle: context.resourceBundle)
        self.localization = localization
        self.configurationStore = configurationStore
            ?? R2ConfigurationStore(storage: context.storage, localization: localization)
        self.uploader = uploader
        self.objectChecker = objectChecker
        self.filePicker = filePicker ?? { Self.chooseFile(localization: localization) }
        self.clipboard = clipboard ?? R2SystemClipboardWriter()
        self.completionNotifier = completionNotifier
            ?? R2SystemUploadCompletionNotifier(localization: localization)
        self.progressPresenter = progressPresenter
            ?? R2UploadProgressPresenter(localization: localization)
        self.logger = logger ?? Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools",
            category: "CloudflareR2Plugin"
        )
        self.terminalStatusDuration = terminalStatusDuration
        rowDescriptor = PluginPanelRowDescriptor(
            controlStyle: .button,
            menuActionBehavior: .dismissBeforeHandling,
            buttonTitleProvider: {
                localization.string("panel.button.choose", defaultValue: "选择")
            }
        )
    }

    var shortcutDefinitions: [PluginShortcutDefinition] {
        [PluginShortcutDefinition(
            id: ShortcutID.upload,
            title: localization.string(
                "shortcut.upload.title",
                defaultValue: "选择文件并上传"
            ),
            description: localization.string(
                "shortcut.upload.description",
                defaultValue: "打开文件选择器并上传到 Cloudflare R2。"
            ),
            actionID: ShortcutID.upload,
            scope: .global,
            defaultBinding: nil,
            isRequired: false,
            settingsGroupID: "upload",
            settingsGroupTitle: localization.string(
                "shortcut.group.title",
                defaultValue: "上传"
            ),
            settingsGroupDescription: localization.string(
                "shortcut.group.description",
                defaultValue: "设置打开 R2 文件上传器的全局快捷键。"
            )
        )]
    }

    var actionDefinitions: [ActionDefinition] {
        [ActionDefinition(
            key: ActionKey(providerID: metadata.id, actionID: ActionID.upload),
            title: localization.string(
                "action.upload.title",
                defaultValue: "选择文件并上传到 R2"
            ),
            description: metadata.defaultDescription,
            keywords: [
                "R2",
                "S3",
                "Cloudflare",
                localization.string("action.upload.keyword", defaultValue: "上传"),
            ],
            systemImage: metadata.iconName,
            externalInvocationPolicy: .unavailable,
            capabilities: [.foregroundInteractive, .cancellable],
            concurrencyPolicy: .rejectWhileRunning,
            executionTimeoutSeconds: 3600
        )]
    }

    func actionAvailability(for reference: ActionReference) -> ActionAvailability {
        guard reference.key == actionDefinitions.first?.key else {
            return .unavailable(PluginKitLocalization.actionUnavailable)
        }
        return isConfigured
            ? .available
            : .unavailable(localization.string(
                "error.configuration.incomplete",
                defaultValue: "请先完成 R2 配置。"
            ))
    }

    func beginAction(_ invocation: ActionInvocation) throws -> ActionExecutionHandle {
        let availability = actionAvailability(for: invocation.reference)
        guard availability.isAvailable else {
            return ActionExecutionHandle {
                .failed(message: availability.reason ?? PluginKitLocalization.actionUnavailable)
            }
        }

        return ActionExecutionHandle(operation: { [weak self] in
            guard let self, !Task.isCancelled else { return .cancelled }
            guard let fileURL = self.filePicker() else { return .cancelled }
            guard !Task.isCancelled else { return .cancelled }
            let task = self.beginUpload(fileURL)
            do {
                _ = try await task.value
                return .succeeded()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(message: localizedMessage(for: error))
            }
        }, cancel: { [weak self] in
            self?.cancelUpload()
        })
    }

    var rowState: PluginPanelRowState {
        PluginPanelRowState(
            subtitle: status.subtitle(localization: localization),
            isOn: status.isUploading,
            isEnabled: !status.isUploading,
            isAvailable: true,
            detail: nil,
            errorMessage: status.errorMessage
        )
    }

    var settingsPage: PluginSettingsPage? {
        .workspace(description: metadata.defaultDescription, scrolling: .host) { [weak self] _ in
            if let self {
                R2SettingsView(plugin: self, localization: localization)
            } else {
                EmptyView()
            }
        }
    }

    func deactivate(reason: PluginDeactivationReason) {
        cancelUpload()
    }

    func handleShortcutAction(id: String) {
        guard id == ShortcutID.upload else { return }
        chooseAndUpload()
    }

    func handleAction(_ action: PluginPanelAction) {
        guard case let .invokeAction(id) = action, id == ControlID.upload else { return }
        chooseAndUpload()
    }

    func chooseAndUpload() {
        guard isConfigured else {
            status = .failed(localization.string(
                "error.configuration.openSettings",
                defaultValue: "请先在设置中完成 R2 配置。"
            ))
            notifyStateChange()
            scheduleStatusReset(generation: uploadGeneration)
            requestSettingsPresentation?()
            return
        }
        guard let fileURL = filePicker() else { return }
        let task = beginUpload(fileURL)
        Task {
            _ = try? await task.value
        }
    }

    @discardableResult
    func beginUpload(_ fileURL: URL) -> Task<R2UploadResult, Error> {
        cancelActiveUpload(updateStatus: false)
        uploadGeneration &+= 1
        let generation = uploadGeneration
        let fileName = fileURL.lastPathComponent
        status = .preparing(fileName)
        notifyStateChange()
        let task = Task { [weak self] () throws -> R2UploadResult in
            guard let self else { throw CancellationError() }
            do {
                return try await self.prepareAndUpload(fileURL, generation: generation)
            } catch {
                self.handlePreparationError(error, generation: generation)
                throw error
            }
        }
        uploadTask = task
        return task
    }

    func cancelUpload() {
        cancelActiveUpload(updateStatus: true)
    }

    private var isConfigured: Bool {
        configurationStore.configuration.isComplete
            && configurationStore.hasStoredSecret
    }

    private func prepareAndUpload(
        _ fileURL: URL,
        generation: UInt64
    ) async throws -> R2UploadResult {
        var proposedName = fileURL.lastPathComponent
        let configuration = configurationStore.configuration
        let secret = try configurationStore.loadSecret()

        while true {
            guard let objectName = await progressPresenter.requestObjectName(
                fileName: proposedName
            ) else {
                if generation == uploadGeneration {
                    uploadTask = nil
                    status = .idle
                    notifyStateChange()
                }
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard generation == uploadGeneration else { throw CancellationError() }

            let exists = try await objectChecker.objectExists(
                objectName: objectName,
                configuration: configuration,
                secretAccessKey: secret
            )
            try Task.checkCancellation()
            guard generation == uploadGeneration else { throw CancellationError() }
            if exists {
                let resolution = await progressPresenter.requestConflictResolution(
                    fileName: objectName
                )
                try Task.checkCancellation()
                guard generation == uploadGeneration else { throw CancellationError() }
                if resolution == .rename {
                    proposedName = R2UploadNameGenerator.randomFileName(
                        preservingExtensionOf: objectName
                    )
                    continue
                }
                if resolution == .cancelled {
                    throw CancellationError()
                }
            }

            progressPresenter.beginProgress(fileName: objectName) { [weak self] in
                self?.cancelUpload()
            }
            status = .uploading(objectName, progress: 0)
            notifyStateChange()
            let progressRelay = R2ProgressRelay { [weak self] progress in
                Task { @MainActor in
                    self?.updateProgress(
                        progress,
                        fileName: objectName,
                        generation: generation
                    )
                }
            }
            return try await performUpload(
                fileURL,
                objectName: objectName,
                configuration: configuration,
                secretAccessKey: secret,
                generation: generation,
                progressRelay: progressRelay
            )
        }
    }

    private func performUpload(
        _ fileURL: URL,
        objectName: String,
        configuration: R2Configuration,
        secretAccessKey: String,
        generation: UInt64,
        progressRelay: R2ProgressRelay
    ) async throws -> R2UploadResult {
        do {
            let result = try await uploader.upload(
                fileURL: fileURL,
                objectName: objectName,
                configuration: configuration,
                secretAccessKey: secretAccessKey,
                progress: progressRelay.report
            )
            try Task.checkCancellation()
            guard generation == uploadGeneration else {
                throw CancellationError()
            }

            uploadTask = nil
            progressPresenter.dismiss()
            status = .succeeded(result)
            notifyStateChange()
            let shouldCopyLink = completionNotifier.notify(
                fileName: objectName,
                result: result
            )
            if shouldCopyLink, let url = result.url {
                clipboard.copy(url.absoluteString)
            }
            scheduleStatusReset(generation: generation)
            logger.info(
                "R2 upload succeeded for object \(result.objectKey, privacy: .public)"
            )
            return result
        } catch {
            if generation != uploadGeneration
                || Task.isCancelled
                || Self.isCancellation(error)
            {
                if generation == uploadGeneration {
                    uploadTask = nil
                    progressPresenter.dismiss()
                    status = .idle
                    notifyStateChange()
                }
                throw CancellationError()
            }
            uploadTask = nil
            progressPresenter.dismiss()
            status = .failed(localizedMessage(for: error))
            notifyStateChange()
            scheduleStatusReset(generation: generation)
            logger.error(
                "R2 upload failed: \(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private func handlePreparationError(_ error: Error, generation: UInt64) {
        guard generation == uploadGeneration,
              case .preparing = status else { return }
        uploadTask = nil
        progressPresenter.dismiss()
        if Task.isCancelled || Self.isCancellation(error) {
            status = .idle
        } else {
            status = .failed(localizedMessage(for: error))
            scheduleStatusReset(generation: generation)
            logger.error(
                "R2 object check failed: \(error.localizedDescription, privacy: .private)"
            )
        }
        notifyStateChange()
    }

    private func cancelActiveUpload(updateStatus: Bool) {
        uploadGeneration &+= 1
        uploadTask?.cancel()
        uploadTask = nil
        progressPresenter.dismiss()
        statusResetTask?.cancel()
        statusResetTask = nil
        if updateStatus, status != .idle {
            status = .idle
            notifyStateChange()
            logger.info("R2 upload cancelled")
        }
    }

    private func updateProgress(
        _ progress: Double,
        fileName: String,
        generation: UInt64
    ) {
        guard generation == uploadGeneration, status.isUploading else { return }
        let clamped = min(1, max(0, progress))
        progressPresenter.update(progress: clamped)
        status = .uploading(fileName, progress: clamped)
        notifyStateChange()
    }

    private func scheduleStatusReset(generation: UInt64) {
        statusResetTask?.cancel()
        guard let terminalStatusDuration else { return }
        statusResetTask = Task { [weak self] in
            do {
                try await Task.sleep(for: terminalStatusDuration)
            } catch {
                return
            }
            guard let self,
                  generation == self.uploadGeneration,
                  !self.status.isUploading else {
                return
            }
            self.status = .idle
            self.statusResetTask = nil
            self.notifyStateChange()
        }
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private func localizedMessage(for error: Error) -> String {
        if let uploadError = error as? R2UploadError {
            return uploadError.message(localization: localization)
        }
        if let secretError = error as? R2SecretStoreError {
            return secretError.message(localization: localization)
        }
        return error.localizedDescription
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func chooseFile(localization: PluginLocalization) -> URL? {
        let panel = NSOpenPanel()
        panel.title = localization.string(
            "filePicker.title",
            defaultValue: "选择要上传到 R2 的文件"
        )
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        PluginPresentationSafety.prepareForWindowOrdering()
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum R2UploadStatus: Equatable {
    case idle
    case preparing(String)
    case uploading(String, progress: Double)
    case succeeded(R2UploadResult)
    case failed(String)

    var isUploading: Bool {
        switch self {
        case .preparing, .uploading:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    var errorMessage: String? {
        if case let .failed(message) = self { message } else { nil }
    }

    var subtitle: String {
        subtitle(localization: PluginLocalization(bundle: .main))
    }

    func subtitle(localization: PluginLocalization) -> String {
        switch self {
        case .idle:
            localization.string(
                "status.idle",
                defaultValue: "上传文件到 Cloudflare R2"
            )
        case let .preparing(name):
            localization.format(
                "status.preparing",
                defaultValue: "准备上传 %@…",
                name
            )
        case let .uploading(name, progress):
            localization.format(
                "status.uploading",
                defaultValue: "正在上传 %@… %d%%",
                name,
                Int(progress * 100)
            )
        case let .succeeded(result):
            localization.format(
                "status.succeeded",
                defaultValue: "上传完成：%@",
                result.objectKey
            )
        case .failed:
            localization.string("status.failed", defaultValue: "上传失败")
        }
    }
}
