import AppKit
import AVFoundation
import XCTest
@testable import ScreenshotPlugin

@available(macOS 15, *)
final class RecordingZoomExporterTests: XCTestCase {
    func testZoomedMovieKeepsDurationSizeOrientationAndAudio() async throws {
        for rotated in [false, true] {
            let folder = try temporaryFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("original.mov")
            let destination = folder.appendingPathComponent("zoom.mov")
            try await makeMovie(at: source, rotated: rotated)
            let originalData = try Data(contentsOf: source)
            let events = [RecordingZoomEvent(time: 0.3, kind: .click, point: CGPoint(x: 0.8, y: 0.2))]
            try await RecordingZoomExporter.export(source: source, destination: destination, events: events)
            XCTAssertEqual(try Data(contentsOf: source), originalData, "The original stays recoverable")

            let input = AVURLAsset(url: source), output = AVURLAsset(url: destination)
            let inputDuration = try await input.load(.duration).seconds
            let outputDuration = try await output.load(.duration).seconds
            XCTAssertEqual(outputDuration, inputDuration, accuracy: 1.0 / 30)
            let videoTracks = try await output.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(videoTracks.first)
            let frameRate = try await track.load(.nominalFrameRate)
            XCTAssertEqual(frameRate, 60, accuracy: 0.01)
            let audioTracks = try await output.loadTracks(withMediaType: .audio)
            XCTAssertEqual(audioTracks.count, 1)

            let original = try await frame(from: input, at: 1)
            let result = try await frame(from: output, at: 1)
            XCTAssertEqual(result.pixelsWide, rotated ? 240 : 320)
            XCTAssertEqual(result.pixelsHigh, rotated ? 320 : 240)
            let crop = RecordingZoomPlan(events: events, duration: inputDuration).crop(at: 1)
            XCTAssertLessThan(crop.width, 1)
            // Compare decoded pixels in display orientation; this catches vertical flips and a lost track transform.
            for point in [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.9)] {
                let expected = try XCTUnwrap(original.colorAt(
                    x: Int((crop.minX + crop.width * point.x) * CGFloat(original.pixelsWide)),
                    y: Int((crop.minY + crop.height * point.y) * CGFloat(original.pixelsHigh)))?.usingColorSpace(.sRGB))
                let actual = try XCTUnwrap(result.colorAt(x: Int(point.x * CGFloat(result.pixelsWide)),
                                                          y: Int(point.y * CGFloat(result.pixelsHigh)))?.usingColorSpace(.sRGB))
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.06, "\(point)")
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.06, "\(point)")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["original.mov", "zoom.mov"])
        }
    }

    func testSparseScreenUpdatesStillProduceSixtyFramesPerSecond() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.mov")
        let destination = folder.appendingPathComponent("zoom.mov")
        try await makeMovie(at: source, rotated: false, frameStride: 30)
        try await RecordingZoomExporter.export(source: source, destination: destination, events: [
            .init(time: 0.3, kind: .click, point: CGPoint(x: 0.8, y: 0.2)), .init(time: 0.4, kind: .release),
        ])
        let asset = AVURLAsset(url: destination)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { times.append(sample.presentationTimeStamp.seconds) }
        }
        XCTAssertGreaterThanOrEqual(times.count, 179, "The camera keeps animating while the screen is unchanged")
        XCTAssertLessThanOrEqual(zip(times.dropFirst(), times).map { $0 - $1 }.max() ?? .infinity, 1.0 / 60 + 0.00001)
    }

    func testWithoutZoomTheOriginalBytesArePublishedUnchanged() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.mov")
        let destination = folder.appendingPathComponent("unchanged.mov")
        try await makeMovie(at: source, rotated: true)
        let originalData = try Data(contentsOf: source)
        // A click too close to the end has no room to zoom in and out.
        try await RecordingZoomExporter.export(source: source, destination: destination, events: [
            .init(time: 2.8, kind: .click, point: CGPoint(x: 0.8, y: 0.2)),
        ])
        XCTAssertEqual(try Data(contentsOf: destination), originalData)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
    }

    func testCancellationAndCollisionsLeaveExistingFilesUntouched() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original.mov")
        let destination = folder.appendingPathComponent("zoom.mov")
        try await makeMovie(at: source, rotated: false)
        let originalData = try Data(contentsOf: source)
        let events = [RecordingZoomEvent(time: 0.3, kind: .click, point: CGPoint(x: 0.8, y: 0.2))]
        let (updates, continuation) = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let task = Task {
            try await RecordingZoomExporter.export(source: source, destination: destination, events: events) { progress in
                if progress == 0 {
                    continuation.yield(())
                    gate.wait()
                }
            }
        }
        var iterator = updates.makeAsyncIterator()
        await iterator.next()
        task.cancel()
        gate.signal()
        do {
            try await task.value
            XCTFail("Cancelled export must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["original.mov"])

        let sentinel = Data("keep existing destination".utf8)
        try sentinel.write(to: destination)
        for target in [destination, source] {
            do {
                try await RecordingZoomExporter.export(source: source, destination: target, events: events)
                XCTFail("An occupied destination must not be replaced")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), originalData)
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func frame(from asset: AVAsset, at seconds: Double) async throws -> NSBitmapImageRep {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return NSBitmapImageRep(cgImage: result.image)
    }

    private func makeMovie(at url: URL, rotated: Bool, frameStride: Int = 1) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                       AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                       AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        if rotated { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
        ])
        writer.add(video)
        writer.add(audio)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let samples = try silentAudio()
        XCTAssertTrue(audio.append(samples))
        audio.markAsFinished()

        var created: CVPixelBuffer?
        XCTAssertTrue(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &created) == kCVReturnSuccess)
        let pixels = try XCTUnwrap(created)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<240 {
            for x in 0..<320 {
                let offset = y * stride + x * 4
                base[offset] = 180
                base[offset + 1] = UInt8(y * 255 / 239)
                base[offset + 2] = UInt8(x * 255 / 319)
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for index in Swift.stride(from: 0, to: 90, by: frameStride) {
            while !video.isReadyForMoreMediaData {
                if let error = writer.error { throw error }
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        XCTAssertTrue(writer.status == .completed)
        if let error = writer.error { throw error }
    }

    private func silentAudio() throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertTrue(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr)
        var block: CMBlockBuffer?
        let count = 3 * 48000
        XCTAssertTrue(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: count * 2, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: count * 2, flags: 0, blockBufferOut: &block) == noErr)
        let data = try XCTUnwrap(block)
        XCTAssertTrue(CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: count * 2) == noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: .zero,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let audioFormat = try XCTUnwrap(format)
        XCTAssertTrue(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: audioFormat, sampleCount: count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample) == noErr)
        return try XCTUnwrap(sample)
    }
}
