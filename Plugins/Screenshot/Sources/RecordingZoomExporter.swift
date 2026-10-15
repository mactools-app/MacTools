import AVFoundation
import CoreImage
import Foundation

/// Render a second movie without modifying the captured source or an existing destination.
@available(macOS 15, *)
enum RecordingZoomExporter {
    static func export(source: URL, destination: URL, events: [RecordingZoomEvent],
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        let files = FileManager.default
        guard source.isFileURL, destination.isFileURL,
              source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath()
        else { throw RecordingZoomExportError.invalidDestination }
        guard !files.fileExists(atPath: destination.path) else { throw RecordingZoomExportError.destinationExists }

        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              try await !asset.loadTracks(withMediaType: .video).isEmpty
        else { throw RecordingZoomExportError.noVideo }
        let plan = RecordingZoomPlan(events: events, duration: duration)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".mactools-zoom-\(UUID().uuidString).mov")
        guard !files.fileExists(atPath: partial.path) else { throw RecordingZoomExportError.destinationExists }
        defer { try? files.removeItem(at: partial) }
        if !plan.hasZoom {
            progress?(0)
            try Task.checkCancellation()
            try files.copyItem(at: source, to: partial)
            try Task.checkCancellation()
            try files.moveItem(at: partial, to: destination)
            progress?(1)
            return
        }
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
            let frame = CGRect(origin: .zero, size: request.renderSize)
            let normalized = plan.crop(at: request.compositionTime.seconds)
            let crop = CGRect(x: normalized.minX * frame.width,
                              y: (1 - normalized.maxY) * frame.height,
                              width: normalized.width * frame.width,
                              height: normalized.height * frame.height)
            // AVFoundation has already applied the track's display transform.
            // Clamp before scaling so fractional edge samples cannot expose transparent borders.
            let image = request.sourceImage.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: frame.width / crop.width, y: frame.height / crop.height))
                .cropped(to: frame)
            request.finish(with: image, context: nil)
        })
        // Static screens can have sparse source frames. Keep camera motion independent of those updates.
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw RecordingZoomExportError.unsupportedMovie }
        session.videoComposition = composition

        let updates = session.states(updateInterval: 0.1)
        let observer = progress.map { report in
            Task {
                for await state in updates {
                    if Task.isCancelled { break }
                    if case .exporting(let value) = state { report(value.fractionCompleted) }
                }
            }
        }
        defer { observer?.cancel() }
        progress?(0)
        try Task.checkCancellation()
        try await session.export(to: partial, as: .mov)
        try Task.checkCancellation()
        // Same-directory publication is atomic; moveItem refuses to replace an existing file.
        try files.moveItem(at: partial, to: destination)
        progress?(1)
    }
}

enum RecordingZoomExportError: Error {
    case invalidDestination
    case destinationExists
    case noVideo
    case unsupportedMovie
}
