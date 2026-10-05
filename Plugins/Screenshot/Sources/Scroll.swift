import AppKit
import ScreenCaptureKit

/// A continuous, bounded frame source feeds the independent stitching worker.
@MainActor
final class ScrollSession {
    var onFinish: ((Result<CGImage?, Error>) -> Void)?
    let region: CaptureRegion
    private let environment: ScreenshotEnvironment
    private let panel: CaptureStatusPanel
    private let outline: CaptureRegionOutlineWindow
    private let controls: CaptureControls
    private let capture = ScrollCapture()
    private var source: ScrollFrameSource?
    private var session: CaptureStreamSession?
    private var startupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var firstFrameTask: Task<Void, Never>?
    private var pendingResult: Result<CGImage?, Error>?
    private var finishing = false
    private var cancelled = false
    private var discardPendingFrames = false
    private var receivedFrame = false
    private var done = false

    init(region: CaptureRegion, environment: ScreenshotEnvironment) {
        self.region = region
        self.environment = environment
        panel = CaptureStatusPanel(primaryTitle: environment.string("scroll.finish", "完成"),
                                   cancelTitle: environment.string("scroll.cancel", "取消"))
        outline = CaptureRegionOutlineWindow(region: region)
        controls = CaptureControls([outline, panel])
        panel.onPrimary = { [weak self] in self?.finish() }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    func start() {
        guard startupTask == nil, session == nil, !done else { return }
        // Cleared on completion; native callbacks must outlive plugin deactivation when stopping.
        capture.onFinish = { [self] result in received(result) }
        capture.onProgress = { [weak self] screens in
            guard let self, !finishing else { return }
            panel.update(environment.format("scroll.progress", "在框里向下滚动内容 · 已拼接 %.1f 屏", screens))
        }
        capture.onUnmatched = { [weak self] in
            guard let self, !finishing else { return }
            panel.update(environment.string("scroll.unmatched", "未找到连续内容，请放慢滚动或向上滚动少许"))
        }
        panel.update(environment.string("capture.preparing", "正在准备…"))
        startupTask = Task { [self] in
            defer { startupTask = nil }
            do {
                let filter = try await CaptureSessionPreparation.filter(region: region, controls: controls)
                try Task.checkCancellation()
                let configuration = CaptureSessionPreparation.configuration(region: region, framesPerSecond: 10, showsCursor: false)
                configuration.queueDepth = 3
                let source = ScrollFrameSource()
                self.source = source
                let session = CaptureStreamSession(filter: filter, configuration: configuration)
                self.session = session
                session.onStopped = { [weak self] result in self?.captureStopped(result) }
                session.onStarted = { [weak self] in self?.waitForFirstFrame() }
                session.onWaiting = { [weak self, weak session] in
                    guard let self, let session else { return }
                    panel.update(environment.string("capture.stoppingSlowly", "正在等待屏幕采集停止…"),
                                 primaryEnabled: session.canRetryStop)
                }
                try session.stream.addStreamOutput(source, type: .screen, sampleHandlerQueue: source.queue)
                processingTask = Task { [self] in
                    for await frame in source.frames {
                        guard !Task.isCancelled, !cancelled else { break }
                        receivedFrame = true
                        firstFrameTask?.cancel()
                        firstFrameTask = nil
                        guard !discardPendingFrames else { continue }
                        await capture.append(frame)
                    }
                    if !done, !cancelled, pendingResult == nil { capture.finish() }
                }
                outline.show()
                panel.show(near: region.globalRect, displayID: region.display.id)
                session.start()
            } catch {
                received(.failure(error))
            }
        }
    }

    func finish() {
        guard !done else { return }
        guard let session else { cancel(); return }
        finishing = true
        panel.update(environment.string("scroll.finishing", "正在完成长截图…"), primaryEnabled: false)
        session.stop()
    }

    func cancel() {
        guard !done else { return }
        cancelled = true
        pendingResult = .success(nil)
        startupTask?.cancel()
        processingTask?.cancel()
        capture.cancel()
        if let session, !session.isStopped { session.stop() }
        else { end(.success(nil)) }
    }

    func displayTopologyChanged() {
        do { try region.validate() } catch {
            discardPendingFrames = true
            outline.orderOut(nil)
            finish()
        }
    }

    private func waitForFirstFrame() {
        guard !receivedFrame, !finishing, !cancelled, !done else { return }
        firstFrameTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.received(.failure(ScrollCaptureError.noFrames))
        }
    }

    private func received(_ result: Result<CGImage?, Error>) {
        guard !done, pendingResult == nil else { return }
        pendingResult = result
        if let session, !session.isStopped {
            finishing = true
            session.stop()
        } else { end(result) }
    }

    private func captureStopped(_ result: Result<Void, Error>) {
        outline.orderOut(nil)
        firstFrameTask?.cancel()
        firstFrameTask = nil
        if case .failure(let error) = result, !cancelled { pendingResult = .failure(error) }
        if let session, let source { try? session.stream.removeStreamOutput(source, type: .screen) }
        // Finish on the sample queue so the last buffered complete frame is drained before composition.
        source?.finish()
        if let pendingResult { end(pendingResult) }
        else if source == nil { received(.failure(ScrollCaptureError.noFrames)) }
    }

    private func end(_ result: Result<CGImage?, Error>) {
        guard !done else { return }
        done = true
        firstFrameTask?.cancel()
        firstFrameTask = nil
        source?.finish()
        processingTask?.cancel()
        processingTask = nil
        capture.onFinish = nil
        capture.onProgress = nil
        capture.onUnmatched = nil
        capture.cancel()
        controls.hide()
        session = nil
        source = nil
        let completion = onFinish
        onFinish = nil
        completion?(result)
    }
}
