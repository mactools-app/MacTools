import AppKit

/// Serializes capture modes and invalidates pending startup work when the plugin is disabled.
@MainActor
final class ScreenshotCoordinator {
    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var isBusy: Bool { controller != nil || recorder != nil || scrollSession != nil || exportTask != nil }
    var isRecording: Bool { recorder != nil }
    var isScrolling: Bool { scrollSession != nil }

    private let environment: ScreenshotEnvironment
    private let overlayPool: CaptureOverlayPool
    private var controller: CaptureController?
    private var recorder: AnyObject?
    /// A recorder whose capture has ended while its auto-zoom movie renders. It does not block other modes.
    private var processingRecorder: AnyObject?
    private var scrollSession: ScrollSession?
    private var exportTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    /// Changes only when the plugin cancels all work. A recording can finish while a later screenshot
    /// is in progress, so its messages must not depend on `generation`.
    private(set) var sessionToken: UInt64 = 0

    init(environment: ScreenshotEnvironment) {
        self.environment = environment
        overlayPool = CaptureOverlayPool(environment: environment)
    }

    func prepareCaptureSurfaces() { overlayPool.prepare() }

    func refreshDisplayTopology() {
        controller?.dismiss()
        if #available(macOS 15, *), let recorder = recorder as? Recorder { recorder.displayTopologyChanged() }
        scrollSession?.displayTopologyChanged()
        overlayPool.prepare()
    }

    func capture(quick: Bool) {
        if #available(macOS 15, *), let recorder = recorder as? Recorder { recorder.stop(); return }
        if let scrollSession { scrollSession.finish(); return }
        guard !isBusy else { return }
        generation &+= 1
        let requestGeneration = generation
        let controller = CaptureController(quick: quick, environment: environment, pool: overlayPool)
        self.controller = controller
        controller.onFinish = { [weak self] in
            guard let self, generation == requestGeneration else { return }
            self.controller = nil
            onStateChange?()
        }
        controller.onError = { [weak self] message in
            guard let self, generation == requestGeneration else { return }
            report(message)
        }
        controller.onRecord = { [weak self] request in
            guard let self, generation == requestGeneration else { return }
            startRecording(request)
        }
        controller.onScroll = { [weak self] request in
            guard let self, generation == requestGeneration else { return }
            startScroll(request)
        }
        onStateChange?()
        controller.start()
    }

    func cancel() {
        generation &+= 1
        sessionToken &+= 1
        exportTask?.cancel()
        exportTask = nil
        controller?.onFinish = nil
        controller?.dismiss()
        controller = nil
        scrollSession?.cancel()
        if #available(macOS 15, *) {
            (recorder as? Recorder)?.cancel()
            (processingRecorder as? Recorder)?.cancel()
        }
        environment.closeAll()
        overlayPool.release()
        onStateChange?()
    }

    private func startRecording(_ request: CaptureRegion) {
        guard #available(macOS 15, *) else {
            report(environment.string("record.requiresNewerSystem", "录屏需要 macOS 15 或更高版本"))
            return
        }
        guard processingRecorder == nil else {
            report(environment.string("record.processingBusy", "正在生成自动缩放视频，请稍后再录制"))
            return
        }
        let requestSession = sessionToken
        let session = Recorder(region: request, environment: environment)
        recorder = session
        session.onProcessing = { [weak self, weak session] in
            guard let self, let session, recorder === session else { return }
            recorder = nil
            processingRecorder = session
            onStateChange?()
        }
        session.onFinish = { [weak self, weak session] result in
            guard let self, let session else { return }
            if recorder === session { recorder = nil }
            else if processingRecorder === session { processingRecorder = nil }
            else { return }
            onStateChange?()
            recordingFinished(result, session: requestSession)
        }
        onStateChange?()
        session.start()
    }

    /// Reports a finished recording unless the plugin cancelled its session.
    func recordingFinished(_ result: Result<URL, Error>, session: UInt64) {
        guard session == sessionToken else { return }
        switch result {
        case .success(let url):
            let folderName = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
            environment.showToast(environment.format("record.saved", "录屏已保存到「%@」", folderName))
        case .failure(let error as RecordingProcessingError):
            let name = error.original.lastPathComponent
            environment.showToast(error.cause is CancellationError
                ? environment.format("record.processingCancelled", "已保留原始录像：%@", name)
                : environment.format("record.processingFailed", "自动缩放生成失败，已保留原始录像：%@", name))
        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let message: String
            switch error {
            case is RecordingError:
                message = environment.string("record.unsupportedResolution", "当前区域超出硬件编码能力，请缩小录制范围")
            case is RecordingZoomError:
                message = environment.string("record.pointerMonitorUnavailable", "无法读取鼠标操作，请重试或关闭自动缩放")
            default:
                message = environment.captureErrorDescription(error)
            }
            report(environment.format("record.failed", "录屏失败：%@", message))
        }
    }

    private func startScroll(_ request: CaptureRegion) {
        let requestGeneration = generation
        let session = ScrollSession(region: request, environment: environment)
        scrollSession = session
        session.onFinish = { [weak self, weak session] result in
            guard let self, let session, scrollSession === session else { return }
            scrollSession = nil
            guard generation == requestGeneration else { onStateChange?(); return }
            switch result {
            case .success(let image):
                if let image {
                    exportTask = Task { [weak self] in
                        guard let self else { return }
                        defer {
                            if generation == requestGeneration { exportTask = nil; onStateChange?() }
                        }
                        await ScreenshotOutput.finishLong(image, scale: request.scale, environment: environment)
                    }
                }
            case .failure(let error):
                if !(error is CancellationError) {
                    report(environment.format("scroll.failed", "滚动截图失败：%@", scrollErrorDescription(error)))
                }
            }
            onStateChange?()
        }
        onStateChange?()
        session.start()
    }

    private func scrollErrorDescription(_ error: Error) -> String {
        switch error {
        case ScrollCaptureError.noFrames:
            return environment.string("scroll.noFrames", "尚未采集到图片，请稍后重试")
        case ScrollCaptureError.outputTooLarge:
            return environment.string("scroll.outputTooLarge", "长截图已达大小上限，请缩小截图范围或分段截取")
        case ScrollCaptureError.compositionFailed:
            return environment.string("scroll.compositionFailed", "无法合成长截图，请缩小截图范围后重试")
        default: return environment.captureErrorDescription(error)
        }
    }

    private func report(_ message: String) {
        onError?(message)
        environment.showToast(message)
    }
}
