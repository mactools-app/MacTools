import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScreenshotRaster: Sendable {
    let image: CGImage
    let logicalSize: CGSize
}

/// ImageIO encoding is independent of AppKit view state and always dispatched off the UI actor.
enum ScreenshotImageEncoder {
    private static let worker = ScreenshotEncodingWorker()

    static func png(_ raster: ScreenshotRaster) async throws -> Data {
        let task = Task.detached(priority: .userInitiated) { try await worker.png(raster) }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: { task.cancel() }
    }

    static func encodePNG(_ raster: ScreenshotRaster) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard raster.logicalSize.width > 0, raster.logicalSize.height > 0,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageEncodingError.failed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: CGFloat(raster.image.width) * 72 / raster.logicalSize.width,
            kCGImagePropertyDPIHeight: CGFloat(raster.image.height) * 72 / raster.logicalSize.height,
        ]
        CGImageDestinationAddImage(destination, raster.image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageEncodingError.failed }
        return data as Data
    }

    static func tiff(from png: Data) async -> Data? {
        let task = Task.detached(priority: .utility) { await worker.tiff(png) }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func write(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// Publishes a complete file under an unused name instead of replacing an existing file.
    static func writeNew(_ data: Data, preferred url: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let files = FileManager.default
            let folder = url.deletingLastPathComponent()
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let partial = folder.appendingPathComponent(".mactools-screenshot-\(UUID().uuidString).tmp")
            defer { try? files.removeItem(at: partial) }
            try data.write(to: partial, options: .withoutOverwriting)
            var index = 1
            while true {
                let candidate = numbered(url, index)
                do {
                    // moveItem never replaces an existing destination, so a concurrent writer cannot be lost.
                    try files.moveItem(at: partial, to: candidate)
                    return candidate
                } catch CocoaError.fileWriteFileExists {
                    index += 1
                }
            }
        }.value
    }

    /// Candidate names for an occupied file: the original name, then " 2", " 3", and so on.
    static func numbered(_ url: URL, _ index: Int) -> URL {
        guard index > 1 else { return url }
        return url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent) \(index).\(url.pathExtension)")
    }
}

/// Bound concurrent full-image encodings, including rapid clipboard replacements.
private actor ScreenshotEncodingWorker {
    func png(_ raster: ScreenshotRaster) throws -> Data {
        try autoreleasepool { try ScreenshotImageEncoder.encodePNG(raster) }
    }

    func tiff(_ png: Data) -> Data? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImageFromSource(destination, source, 0, nil)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }
    }
}

enum ImageEncodingError: Error { case failed }
