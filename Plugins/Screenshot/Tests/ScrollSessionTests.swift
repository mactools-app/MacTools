import CoreGraphics
import Foundation
import XCTest
@testable import ScreenshotPlugin

@MainActor
final class ScrollSessionTests: XCTestCase {
    func testFinishReturnsCapturedImageOnlyOnce() async throws {
        let frame = try makeFrame()
        let capture = ScrollCapture()
        var progress: [Double] = []
        var results: [Result<CGImage?, Error>] = []
        capture.onProgress = { progress.append($0) }
        capture.onFinish = { results.append($0) }
        await capture.append(frame)
        capture.finish()
        try await waitUntil { results.count == 1 }
        capture.finish()
        capture.cancel()
        await capture.append(frame)
        XCTAssertEqual(progress, [1])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try results.first?.get()?.height, frame.height)
    }

    func testCancelRejectsSubsequentFramesAndCompletion() async throws {
        let capture = ScrollCapture()
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        capture.cancel()
        await capture.append(try makeFrame())
        capture.finish()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(try results.first?.get())
    }

    func testFinishingBeforeFirstFrameIsAnError() async throws {
        let capture = ScrollCapture()
        var result: Result<CGImage?, Error>?
        capture.onFinish = { result = $0 }
        capture.finish()
        await capture.append(try makeFrame())
        try await waitUntil { result != nil }
        guard case .failure(let error) = result else { return XCTFail("Missing frames must be an error") }
        XCTAssertEqual(error as? ScrollCaptureError, .noFrames)
    }

    func testUnmatchedContentIsNotAppendedAsAnotherFullScreen() throws {
        let first = try makeFrame()
        let stitcher = Stitcher()
        try stitcher.push(first)
        let context = try XCTUnwrap(CGContext(data: nil, width: first.width, height: first.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 0, y: 0, width: first.width, height: first.height))
        XCTAssertEqual(try stitcher.push(XCTUnwrap(context.makeImage())), 0)
        XCTAssertFalse(stitcher.lastMatchAccepted)
        XCTAssertEqual(stitcher.totalRows, first.height)
        XCTAssertEqual(try stitcher.push(first), 0)
        XCTAssertTrue(stitcher.lastMatchAccepted, "A rejected frame must not replace the last accepted reference")
    }

    func testAmbiguousRepeatingContentDoesNotInventAScrollDistance() throws {
        let height = 160
        let previous = (0..<height).flatMap { y in [UInt8](repeating: y % 16 < 8 ? 30 : 220, count: Stitcher.cols) }
        let next = (0..<height).flatMap { y in [UInt8](repeating: (y + 8) % 16 < 8 ? 30 : 220, count: Stitcher.cols) }
        XCTAssertNil(try Stitcher.offset(prev: previous, next: next, height: height))
    }

    func testStitcherReconstructsADocumentAcrossDifferentScrollOffsets() throws {
        let width = 400, viewport = 900
        let document = try makeDocument()
        let stitcher = Stitcher()
        for offset in [0, 300, 650, 650, 1100, 1500] {
            try stitcher.push(try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport))))
        }
        let output = try XCTUnwrap(try stitcher.compose())
        XCTAssertEqual(output.height, document.height)
        XCTAssertEqual(Stitcher.grayColumns(output), Stitcher.grayColumns(document))
    }

    func testAccumulatedOutputCannotExceedThePixelBudget() throws {
        let stats = CaptureBufferStats()
        let stitcher = Stitcher(maximumBytes: 64 * 4 * 367)
        try stitcher.push(trackedFrame(offset: 0, stats: stats))
        try stitcher.push(trackedFrame(offset: 4, stats: stats))
        XCTAssertThrowsError(try stitcher.push(trackedFrame(offset: 8, stats: stats))) {
            XCTAssertEqual($0 as? ScrollCaptureError, .outputTooLarge)
        }
        XCTAssertEqual(stitcher.totalRows, 364)
        XCTAssertEqual(try stitcher.compose()?.height, 364)
    }

    nonisolated private func trackedFrame(offset: Int, stats: CaptureBufferStats) throws -> CGImage {
        let buffer = CapturePixelBuffer(offset: offset, stats: stats)
        var callbacks = CGDataProviderDirectCallbacks(version: 0, getBytePointer: { info in
            let buffer = Unmanaged<CapturePixelBuffer>.fromOpaque(info!).takeUnretainedValue()
            buffer.stats.recordRead()
            return UnsafeRawPointer(buffer.bytes)
        }, releaseBytePointer: nil, getBytesAtPosition: nil, releaseInfo: { info in
            Unmanaged<CapturePixelBuffer>.fromOpaque(info!).release()
        })
        let retained = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(directInfo: retained.toOpaque(), size: off_t(buffer.count), callbacks: &callbacks) else {
            retained.release()
            throw TestError.captureFailed
        }
        return try XCTUnwrap(CGImage(width: 64, height: 360, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for scrolling capture completion")
    }

    func testCancellingPendingCompositionDeliversOnlyCancellation() async throws {
        let frame = try makeFrame()
        let capture = ScrollCapture()
        var results: [Result<CGImage?, Error>] = []
        capture.onFinish = { results.append($0) }
        await capture.append(frame)
        capture.finish()
        capture.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(try XCTUnwrap(results.first).get())
    }

    /// Real captures differ slightly between frames; noise must not reject every later frame as unmatched.
    func testNoisyFramesStillMatchAndAppendEachRowOnce() throws {
        let width = 400, viewport = 900
        let document = try makeDocument()
        var seed: UInt32 = 777
        for amplitude in [10, 20, 40] {
            let stitcher = Stitcher()
            for offset in [0, 300, 650, 1100, 1500] {
                let frame = try XCTUnwrap(document.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport)))
                try stitcher.push(try jittered(frame, amplitude: amplitude, seed: &seed))
            }
            let output = try XCTUnwrap(try stitcher.compose())
            XCTAssertEqual(output.height, document.height, "amplitude: \(amplitude)")
        }
    }

    private func makeDocument(width: Int = 400, height: Int = 2400) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        var seed: UInt32 = 12345
        func random() -> CGFloat {
            seed = seed &* 1664525 &+ 1013904223
            return CGFloat((seed >> 8) & 0xFFFF) / 65535
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<600 {
            context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            context.fill(CGRect(x: random() * 380, y: random() * 2380, width: 8 + random() * 60, height: 4 + random() * 20))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func jittered(_ image: CGImage, amplitude: Int, seed: inout UInt32) throws -> CGImage {
        let bytesPerRow = image.width * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        for i in Swift.stride(from: 0, to: bytesPerRow * image.height, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            let delta = Int((seed >> 8) % UInt32(amplitude * 2 + 1)) - amplitude
            for k in 0..<3 { pixels[i + k] = UInt8(clamping: Int(pixels[i + k]) + delta) }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeFrame(height: Int = 128) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private enum TestError: Error { case captureFailed }
}

private final class CaptureBufferStats: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var mainReads = 0
    private var otherReads = 0
    private let firstBackgroundReadGate: DispatchSemaphore?
    init(firstBackgroundReadGate: DispatchSemaphore? = nil) {
        self.firstBackgroundReadGate = firstBackgroundReadGate
    }
    var liveBytes: Int { lock.withLock { bytes } }
    var mainThreadReads: Int { lock.withLock { mainReads } }
    var backgroundReads: Int { lock.withLock { otherReads } }
    func changeBytes(_ delta: Int) { lock.withLock { bytes += delta } }
    func recordRead() {
        let firstBackgroundRead = lock.withLock {
            if Thread.isMainThread { mainReads += 1; return false }
            otherReads += 1
            return otherReads == 1
        }
        if firstBackgroundRead { _ = firstBackgroundReadGate?.wait(timeout: .now() + 2) }
    }
}

private final class CapturePixelBuffer {
    let bytes: UnsafeMutablePointer<UInt8>
    let count = 64 * 360 * 4
    let stats: CaptureBufferStats
    init(offset: Int, stats: CaptureBufferStats) {
        self.stats = stats
        bytes = .allocate(capacity: count)
        bytes.initialize(repeating: 255, count: count)
        for y in 0..<360 {
            for x in 0..<64 {
                var value = UInt32((y + offset) * 64 + x) &+ 1
                value ^= value >> 16
                value = value &* 0x7feb352d
                value ^= value >> 15
                let gray = UInt8(truncatingIfNeeded: value)
                let index = (y * 64 + x) * 4
                bytes[index] = gray
                bytes[index + 1] = gray
                bytes[index + 2] = gray
            }
        }
        stats.changeBytes(count)
    }
    deinit {
        bytes.deallocate()
        stats.changeBytes(-count)
    }
}
