import CoreGraphics
import Foundation

/// Matches consecutive frames and appends the rows revealed by downward scrolling.
final class Stitcher {
    private(set) var pieces: [CGImage] = []
    private var lastGray: [UInt8] = []      // Horizontal downsampling preserves the original row count.
    private var width = 0, height = 0
    private(set) var lastMatchAccepted = true
    static let cols = 64
    private static let coarseStep = 4       // Minimum row stride in the coarse search.

    private(set) var totalRows = 0
    private let maximumBytes: Int
    private let maximumHeight: Int
    private let maximumWorkingBytes: Int

    init(maximumBytes: Int = 128 * 1024 * 1024, maximumHeight: Int = 32_768,
         maximumWorkingBytes: Int = 384 * 1024 * 1024) {
        self.maximumBytes = maximumBytes
        self.maximumHeight = maximumHeight
        self.maximumWorkingBytes = maximumWorkingBytes
    }

    func reset() {
        pieces.removeAll()
        lastGray.removeAll()
        totalRows = 0
        width = 0
        height = 0
        lastMatchAccepted = true
    }

    /// Reserve six viewport buffers and three output-sized buffers for capture, composition,
    /// and export. This bounds planned pixel allocations, not framework or process-wide RSS.
    private func validate(width: Int, rows: Int, viewportRows: Int) throws {
        guard width > 0, rows > 0, rows <= maximumHeight,
              width <= maximumBytes / 4, rows <= maximumBytes / 4 / width,
              viewportRows <= maximumWorkingBytes / 6 / 4 / width else {
            throw ScrollCaptureError.outputTooLarge
        }
        let remaining = maximumWorkingBytes - viewportRows * width * 4 * 6
        guard rows <= remaining / 3 / 4 / width else {
            throw ScrollCaptureError.outputTooLarge
        }
    }

    /// Returns the number of newly appended rows; zero means no new content was found.
    @discardableResult
    func push(_ frame: CGImage) throws -> Int {
        try Task.checkCancellation()
        try validate(width: frame.width, rows: frame.height, viewportRows: frame.height)
        guard pieces.isEmpty || (frame.width == width && frame.height == height) else {
            throw CaptureFailure.displayChanged
        }
        let gray = Self.grayColumns(frame)
        let added: Int
        if pieces.isEmpty {
            added = frame.height
        } else {
            guard let offset = try Self.offset(prev: lastGray, next: gray, height: height) else {
                lastMatchAccepted = false
                return 0
            }
            added = offset
        }
        lastMatchAccepted = true
        let nextRows = totalRows + added
        if added > 0 {
            try validate(width: frame.width, rows: nextRows, viewportRows: frame.height)
            // Cropped CGImages retain their original provider. Draw into an independently
            // allocated bitmap so a few new rows cannot keep an entire capture alive.
            guard let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - added,
                                                        width: frame.width, height: added)),
                  let context = CGContext(data: nil, width: frame.width, height: added,
                                          bitsPerComponent: 8, bytesPerRow: frame.width * 4,
                                          space: pieces.first?.colorSpace ?? frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScrollCaptureError.compositionFailed
            }
            context.draw(strip, in: CGRect(x: 0, y: 0, width: frame.width, height: added))
            guard let copy = context.makeImage() else { throw ScrollCaptureError.compositionFailed }
            try Task.checkCancellation()
            pieces.append(copy)
        }
        lastGray = gray
        width = frame.width
        height = frame.height
        totalRows = nextRows
        return added
    }

    func compose() throws -> CGImage? {
        try Task.checkCancellation()
        guard let first = pieces.first else { return nil }
        guard let ctx = CGContext(data: nil, width: first.width, height: totalRows, bitsPerComponent: 8,
                                  bytesPerRow: first.width * 4, space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = 0
        for piece in pieces {
            try Task.checkCancellation()
            ctx.draw(piece, in: CGRect(x: 0, y: totalRows - top - piece.height,
                                      width: piece.width, height: piece.height))
            top += piece.height
        }
        return ctx.makeImage()
    }

    /// Produces a narrow grayscale image with full vertical resolution and a top-left origin.
    static func grayColumns(_ image: CGImage) -> [UInt8] {
        let h = image.height
        var data = [UInt8](repeating: 0, count: cols * h)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: h, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: h))
        }
        return data
    }

    /// Score every offset with bounded row samples, then verify nearby offsets at full resolution.
    static func offset(prev: [UInt8], next: [UInt8], height h: Int) throws -> Int? {
        let top = h * 12 / 100                        // Ignore fixed headers near the top edge.
        let minOverlap = max(h * 15 / 100, 8)
        let maxDy = h - top - minOverlap
        guard maxDy > 0 else { return nil }

        return try prev.withUnsafeBufferPointer { p in
            try next.withUnsafeBufferPointer { q in
                func error(_ dy: Int, step: Int) -> Double {
                    var sum = 0, n = 0, y = top
                    while y + dy < h {
                        let a = y * cols, b = (y + dy) * cols
                        for c in 0..<cols { sum += abs(Int(q[a + c]) - Int(p[b + c])) }
                        n += cols
                        y += step
                    }
                    return n == 0 ? .infinity : Double(sum) / Double(n)
                }
                var best = 0, bestErr = Double.infinity
                var scores = [Double](repeating: .infinity, count: maxDy + 1)
                for dy in 0...maxDy {
                    try Task.checkCancellation()
                    let e = error(dy, step: max(coarseStep, (h - top - dy) / 32))
                    scores[dy] = e
                    if e < bestErr { bestErr = e; best = dy }
                }
                let candidate = best
                bestErr = .infinity
                for dy in max(0, candidate - coarseStep)...min(maxDy, candidate + coarseStep) {
                    try Task.checkCancellation()
                    let e = error(dy, step: 1)
                    if e < bestErr { bestErr = e; best = dy }
                }
                // Capture noise raises every score, so an absolute limit alone rejects real matches.
                // Also accept a match that is clearly better than a typical unrelated alignment.
                let finite = scores.filter(\.isFinite).sorted()
                let baseline = finite.isEmpty ? 0 : finite[finite.count / 2]
                guard bestErr <= 6 || (baseline > 1 && bestErr < baseline * 0.7) else { return nil }
                // The footer check scales with the matched noise floor, staying at 6 for clean frames.
                let tolerance = max(6, bestErr * 2)
                if best > 0 {
                    // Repeated or featureless content cannot establish a unique displacement.
                    if scores.enumerated().contains(where: {
                        abs($0.offset - best) > coarseStep && $0.element <= bestErr + 0.5
                    }) { return nil }
                    // A stationary footer must not be copied into the middle of the document.
                    let tailStart = max(top, h - best - max(8, h / 10))
                    var tailError = 0, samples = 0
                    for y in tailStart..<(h - best) {
                        for c in 0..<cols {
                            tailError += abs(Int(q[y * cols + c]) - Int(p[(y + best) * cols + c]))
                            samples += 1
                        }
                    }
                    guard samples > 0, Double(tailError) / Double(samples) <= tolerance else { return nil }
                }
                return best
            }
        }
    }

}

/// Actor isolation keeps matching, copying, and final composition off the main actor.
actor ScrollStitchingWorker {
    private let stitcher: Stitcher

    init(maximumBytes: Int = 128 * 1024 * 1024, maximumHeight: Int = 32_768) {
        stitcher = Stitcher(maximumBytes: maximumBytes, maximumHeight: maximumHeight)
    }

    func push(_ image: CGImage) throws -> (added: Int, totalRows: Int, matched: Bool) {
        let added = try stitcher.push(image)
        return (added, stitcher.totalRows, stitcher.lastMatchAccepted)
    }

    func compose() throws -> CGImage {
        defer { stitcher.reset() }
        guard !stitcher.pieces.isEmpty else { throw ScrollCaptureError.noFrames }
        guard let image = try stitcher.compose() else { throw ScrollCaptureError.compositionFailed }
        return image
    }

    func clear() { stitcher.reset() }
}
