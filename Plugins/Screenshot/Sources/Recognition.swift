import AppKit
import Vision

enum RecognitionKind: Sendable {
    case text, barcode

    @MainActor
    func title(in environment: ScreenshotEnvironment) -> String {
        self == .text ? environment.string("overlay.recognition.text", "提取文字")
            : environment.string("overlay.recognition.barcode", "识别二维码与条形码")
    }

    @MainActor
    func unit(in environment: ScreenshotEnvironment) -> String {
        self == .text ? environment.string("overlay.recognition.lines", "行")
            : environment.string("overlay.recognition.items", "个条码")
    }
}

struct RecognitionResult: Sendable {
    let lines: [String]
    /// Vision uses normalized rectangles with a bottom-left origin.

    var barcodeRects: [CGRect] = []
}

/// Reject stale results even when Vision finishes after cancellation.
@MainActor
final class RecognitionSession {
    typealias Recognize = @Sendable (CGImage, RecognitionKind) async throws -> RecognitionResult

    private let recognize: Recognize
    private var task: Task<Void, Never>?

    init(recognize: @escaping Recognize = { image, kind in
        try await VisionRecognition.shared.recognize(image, kind: kind)
    }) {
        self.recognize = recognize
    }

    deinit { task?.cancel() }

    @discardableResult
    func start(_ image: CGImage, kind: RecognitionKind,
               onResult: @escaping @MainActor (Result<RecognitionResult, Error>) -> Void) -> Task<Void, Never> {
        cancel()
        let work = Task { [weak self, recognize] in
            let result: Result<RecognitionResult, Error>
            do {
                result = .success(try await recognize(image, kind))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            onResult(result)
        }
        task = work
        return work
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Serialize expensive requests away from the main actor.
actor VisionRecognition {
    static let shared = VisionRecognition()
    static let languages = ["zh-Hans", "en-US"]

    func recognize(_ image: CGImage, kind: RecognitionKind) async throws -> RecognitionResult {
        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let result: RecognitionResult
        switch kind {
        case .text:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = Self.languages
            try handler.perform([request])
            let lines = (request.results ?? [])
                .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                .compactMap { $0.topCandidates(1).first?.string }
            result = RecognitionResult(lines: lines)
        case .barcode:
            let request = VNDetectBarcodesRequest()
            try handler.perform([request])
            let found = request.results ?? []
            result = RecognitionResult(lines: found.compactMap(\.payloadStringValue),
                                       barcodeRects: found.map(\.boundingBox))
        }
        try Task.checkCancellation()
        return result
    }

    func warmUp() async {
        guard let ctx = CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Warm up", attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
        ]))
        ctx.textPosition = CGPoint(x: 6, y: 12)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return }
        _ = try? await recognize(image, kind: .text)
    }
}
