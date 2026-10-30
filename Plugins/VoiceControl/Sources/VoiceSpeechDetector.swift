@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Foundation

protocol VoiceSpeechDetecting: Sendable {
    func prepare() async throws
    func detectsSpeech(in pcm: Data) async throws -> Bool
    func reset() async
}

/// One actor owns the converter, recurrent state, and synchronous Core ML work.
/// Only immutable 24 kHz PCM crosses from the capture/UI side.
actor VoiceSpeechDetector: VoiceSpeechDetecting {
    private let modelURL: URL?
    private var model: MLModel?
    private var converter: AVAudioConverter?
    private var hidden: MLMultiArray?
    private var cell: MLMultiArray?
    private var context = [Float](repeating: 0, count: 64)
    private var samples: [Float] = []
    private var speechFrames = 0

    init(modelURL: URL?) { self.modelURL = modelURL }

    func prepare() throws {
        guard let modelURL else { throw VoiceFailure.speechDetection }
        let configuration = MLModelConfiguration()
        // This tiny model also runs on Intel Macs; avoid accelerator startup for onset detection.
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output) else { throw VoiceFailure.speechDetection }
        self.converter = converter
        reset()
    }

    func reset() {
        converter?.reset()
        hidden = nil; cell = nil
        context = [Float](repeating: 0, count: 64)
        samples.removeAll(keepingCapacity: true); speechFrames = 0
    }

    func detectsSpeech(in pcm: Data) throws -> Bool {
        guard let converter, pcm.count.isMultiple(of: 2), pcm.count <= 480_000,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let destination = input.int16ChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount(pcm.count / 3 + 64)) else { throw VoiceFailure.speechDetection }
        input.frameLength = input.frameCapacity
        pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: destination, count: pcm.count))
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard result != .error, error == nil, let floats = output.floatChannelData?[0] else { throw VoiceFailure.speechDetection }
        for probability in try probabilities(Array(UnsafeBufferPointer(start: floats, count: Int(output.frameLength)))) {
            speechFrames = probability >= 0.6 ? speechFrames + 1 : 0
            if speechFrames >= 4 { return true } // 128 ms of sustained speech, independent of tap size.
        }
        return false
    }

    /// Silero's streaming contract is 512 NEW samples plus 64 carried samples.
    /// Arbitrary capture chunks must not become independently padded model windows.
    func probabilities(_ input: [Float]) throws -> [Float] {
        guard let model else { throw VoiceFailure.speechDetection }
        samples.append(contentsOf: input)
        var probabilities: [Float] = []
        var offset = 0
        while samples.count - offset >= 512 {
            let frame = Array(samples[offset..<(offset + 512)])
            let probability: Float = try autoreleasepool {
                let audio = try MLMultiArray(shape: [1, 576], dataType: .float32)
                for (index, value) in (context + frame).enumerated() { audio[index] = NSNumber(value: value) }
                if hidden == nil { hidden = try Self.zeroState(); cell = try Self.zeroState() }
                guard let hidden, let cell else { throw VoiceFailure.speechDetection }
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                    "audio_input": audio, "hidden_state": hidden, "cell_state": cell]))
                guard let probability = result.featureValue(for: "vad_output")?.multiArrayValue,
                      let nextHidden = result.featureValue(for: "new_hidden_state")?.multiArrayValue,
                      let nextCell = result.featureValue(for: "new_cell_state")?.multiArrayValue else { throw VoiceFailure.speechDetection }
                self.hidden = nextHidden; self.cell = nextCell
                return probability[0].floatValue
            }
            probabilities.append(probability)
            context = Array(frame.suffix(64)); offset += 512
        }
        if offset > 0 { samples.removeFirst(offset) }
        return probabilities
    }

    private static func zeroState() throws -> MLMultiArray {
        let state = try MLMultiArray(shape: [1, 128], dataType: .float32)
        for index in 0..<state.count { state[index] = 0 }
        return state
    }
}

/// Last half-second only; microphone audio is never written to disk.
struct VoiceSpeechPreRoll {
    private var pcm = Data()
    mutating func append(_ data: Data) {
        pcm.append(data)
        if pcm.count > 24_000 { pcm.removeFirst(pcm.count - 24_000) }
    }
    mutating func take() -> Data { defer { pcm.removeAll(keepingCapacity: true) }; return pcm }
}
