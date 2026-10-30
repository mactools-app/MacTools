@preconcurrency import AVFoundation
import Foundation

/// Only the audio tap accesses the converter. Its output crosses threads as immutable PCM data.
private final class VoiceCapture: @unchecked Sendable {
    let converter: AVAudioConverter
    let output: AVAudioFormat
    let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(input: AVAudioFormat, continuation: AsyncThrowingStream<Data, Error>.Continuation) throws {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { throw VoiceFailure.audio }
        self.output = output; self.converter = converter; self.continuation = continuation
    }

    func append(_ input: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 24000 / input.format.sampleRate) + 32)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        guard error == nil, status != .error else { continuation.finish(throwing: VoiceFailure.audio); return }
        guard let samples = buffer.int16ChannelData, buffer.frameLength > 0 else { return }
        let data = Data(bytes: samples[0], count: Int(buffer.frameLength) * 2)
        if case .dropped = continuation.yield(data) { continuation.finish(throwing: VoiceFailure.overloaded) }
    }
}

@MainActor
protocol VoiceAudioIO {
    func start() throws -> AsyncThrowingStream<Data, Error>
    func play(_ data: Data) throws
    func stop()
    func observePlayback(_ observer: @escaping (Bool) -> Void)
    func observeOutputLevel(_ observer: @escaping (Float) -> Void)
}

extension VoiceAudioIO {
    func observePlayback(_ observer: @escaping (Bool) -> Void) {}
    func observeOutputLevel(_ observer: @escaping (Float) -> Void) {}
}

enum VoiceAudioMeter {
    static func normalized(rms: Float) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        return min(1, max(0, (20 * log10(rms) + 55) / 45))
    }
    static func level(_ pcm: Data) -> Float {
        guard pcm.count >= 2, pcm.count.isMultiple(of: 2) else { return 0 }
        let sum = pcm.withUnsafeBytes { bytes -> Float in
            var sum: Float = 0
            for offset in stride(from: 0, to: bytes.count, by: 2) {
                let bits = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
                let sample = Float(Int16(bitPattern: bits)) / 32768
                sum += sample * sample
            }
            return sum
        }
        return normalized(rms: sqrt(sum / Float(pcm.count / 2)))
    }
}

@MainActor
final class VoiceAudio: VoiceAudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var installed = false
    private var outputTapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private var queuedFrames = 0
    private var queuedSpeechFrames = 0
    private var playbackObserver: ((Bool) -> Void)?
    private var outputLevelObserver: ((Float) -> Void)?
    func observePlayback(_ observer: @escaping (Bool) -> Void) { playbackObserver = observer }
    func observeOutputLevel(_ observer: @escaping (Float) -> Void) { outputLevelObserver = observer }
    private var playbackGeneration = UUID()

    func start() throws -> AsyncThrowingStream<Data, Error> {
        stop()
        let input = engine.inputNode
        // System echo cancellation supports speaking over the assistant without feeding its voice back.
        try input.setVoiceProcessingEnabled(true)
        let hardwareOutput = engine.outputNode.outputFormat(forBus: 0)
        guard input.inputFormat(forBus: 0).sampleRate > 0, hardwareOutput.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardwareOutput.sampleRate, channels: 1),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false) else { throw VoiceFailure.audio }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: output)
        // Voice-processing IO requires the input node's output and output node's
        // input to match. Its default multichannel capture format can differ from
        // the speaker format; use the processed mono channel in both directions.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        continuation = pair.continuation
        let capture = try VoiceCapture(input: format, continuation: pair.continuation)
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { @Sendable [capture] buffer, _ in capture.append(buffer) }
        installed = true
        let generation = playbackGeneration
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2400, format: format) { @Sendable [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let level = VoiceAudioMeter.normalized(rms: sqrt(sum / Float(buffer.frameLength)))
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation, self.engine.isRunning else { return }
                self.outputLevelObserver?(level)
            }
        }
        outputTapInstalled = true
        engine.prepare()
        do { try engine.start(); player.play() }
        catch { stop(); throw VoiceFailure.audio }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuation?.finish(throwing: VoiceFailure.audio)
            }
        }
        return pair.stream
    }

    func play(_ data: Data) throws {
        guard engine.isRunning, data.count.isMultiple(of: 2), data.count <= 480_000 else { throw VoiceFailure.audio }
        let frames = data.count / 2
        guard frames > 0, queuedFrames + frames <= 24_000 * 30,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw VoiceFailure.overloaded }
        buffer.frameLength = AVAudioFrameCount(frames)
        var sum: Float = 0
        data.withUnsafeBytes { bytes in
            for i in 0..<frames {
                let sample = UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8
                samples[i] = Float(Int16(bitPattern: sample)) / 32768
                sum += samples[i] * samples[i]
            }
        }
        queuedFrames += frames
        let hasSpeech = VoiceAudioMeter.normalized(rms: sqrt(sum / Float(frames))) > 0.05
        if hasSpeech { queuedSpeechFrames += frames; playbackObserver?(true) }
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
                if hasSpeech { self.queuedSpeechFrames = max(0, self.queuedSpeechFrames - frames) }
                if self.queuedSpeechFrames == 0 { self.playbackObserver?(false) }
            }
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        continuation?.finish(); continuation = nil
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        if outputTapInstalled { engine.mainMixerNode.removeTap(onBus: 0); outputTapInstalled = false }
        player.stop(); engine.stop()
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        queuedFrames = 0; queuedSpeechFrames = 0; playbackGeneration = UUID()
        playbackObserver?(false)
        outputLevelObserver?(0)
    }
}
