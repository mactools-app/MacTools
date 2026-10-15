import AppKit
import CoreVideo
import ScreenCaptureKit

struct CaptureDisplay: Sendable, Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let captureRect: CGRect
    let scale: CGFloat

    var pixelWidth: Int { Int((frame.width * scale).rounded()) }
    var pixelHeight: Int { Int((frame.height * scale).rounded()) }

    @MainActor
    static func current() -> [CaptureDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CaptureDisplay(id: id.uint32Value, frame: screen.frame,
                                  captureRect: CGDisplayBounds(id.uint32Value), scale: screen.backingScaleFactor)
        }
    }

    func validate(_ image: CGImage) throws {
        // Never stretch or display a frame captured across a resolution/topology change.
        guard image.width == pixelWidth, image.height == pixelHeight else { throw CaptureFailure.displayChanged }
    }
}

enum CaptureFailure: Error, Equatable {
    case unavailable, timedOut, displayChanged, invalidRegion
}

/// A callback API can finish after cancellation or its deadline. Resume once and discard late frames.
@MainActor
final class CaptureCompletion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var finished = false

    static func receive(
        timeout: Duration = .seconds(2),
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let completion = CaptureCompletion()
        let deadline = Task { @MainActor [weak completion] in
            do { try await Task.sleep(for: timeout) } catch { return }
            completion?.finish(.failure(CaptureFailure.timedOut))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.continuation = continuation
                start { result in
                    Task { @MainActor in completion.finish(result) }
                }
            }
        } onCancel: {
            Task { @MainActor in completion.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

/// Captures only on explicit invocation. Window enumeration is absent from the macOS 26 path.
@MainActor
enum CapturePipeline {
    static func capture(_ displays: [CaptureDisplay]) async throws -> [CGDirectDisplayID: CGImage] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.unavailable }
        var legacyDisplays: [SCDisplay] = []
        if #unavailable(macOS 26) {
            // Keep non-Sendable ScreenCaptureKit discovery objects on this actor.
            let content = try await CaptureSessionPreparation.content()
            try Task.checkCancellation()
            legacyDisplays = content.displays
        }
        let sources = legacyDisplays
        return try await collect(displays) { display in
            let image = try await captureDisplay(display, legacyDisplays: sources)
            try Task.checkCancellation()
            try display.validate(image)
            return image
        }
    }

    /// Bounded concurrency keeps multi-display latency low without submitting an unbounded batch.
    static func collect(
        _ displays: [CaptureDisplay],
        capture: @escaping @MainActor @Sendable (CaptureDisplay) async throws -> CGImage
    ) async throws -> [CGDirectDisplayID: CGImage] {
        guard !displays.isEmpty else { throw CaptureFailure.unavailable }
        return try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
            var pending = displays.makeIterator()
            func submit(_ display: CaptureDisplay) {
                group.addTask {
                    try Task.checkCancellation()
                    return (display.id, try await capture(display))
                }
            }
            for _ in 0..<min(3, displays.count) {
                if let display = pending.next() { submit(display) }
            }
            var images: [CGDirectDisplayID: CGImage] = [:]
            while let (id, image) = try await group.next() {
                try Task.checkCancellation()
                images[id] = image
                if let display = pending.next() { submit(display) }
            }
            return images
        }
    }

    private static func captureDisplay(_ display: CaptureDisplay, legacyDisplays: [SCDisplay]) async throws -> CGImage {
        if #available(macOS 26, *) {
            let configuration = screenshotConfiguration(pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight)
            return try await CaptureCompletion<CGImage>.receive { completion in
                SCScreenshotManager.captureScreenshot(rect: display.captureRect, configuration: configuration) { output, error in
                    if let image = output?.sdrImage { completion(.success(image)) }
                    else { completion(.failure(error ?? CaptureFailure.unavailable)) }
                }
            }
        }

        guard let source = legacyDisplays.first(where: { $0.displayID == display.id }) else {
            throw CaptureFailure.displayChanged
        }
        let filter = SCContentFilter(display: source, excludingWindows: [])
        let configuration = streamConfiguration(pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight)
        return try await CaptureCompletion<CGImage>.receive { completion in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { completion(.success(image)) }
                else { completion(.failure(error ?? CaptureFailure.unavailable)) }
            }
        }
    }

    static func streamConfiguration(pixelWidth: Int, pixelHeight: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        config.shouldBeOpaque = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        // The default also strips shadows and framing from menus and popovers in display captures.
        config.ignoreShadowsSingleWindow = false
        return config
    }

    @available(macOS 26, *)
    static func screenshotConfiguration(pixelWidth: Int, pixelHeight: Int) -> SCScreenshotConfiguration {
        let config = SCScreenshotConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.showsCursor = false
        // Preserve system window framing, including native glass edges and shadows.
        config.ignoreShadows = false
        config.includeChildWindows = true
        config.displayIntent = .local
        config.dynamicRange = .sdr
        return config
    }
}
