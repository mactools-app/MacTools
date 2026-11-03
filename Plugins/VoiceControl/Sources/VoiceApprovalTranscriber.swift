import Foundation

/// Completed, bounded replies only. No task instructions, screen content or phrase hints are supplied.
final class VoiceApprovalTranscriber: Sendable {
    static let modelID = "gpt-transcribe"
    private let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()
    deinit { network.invalidateAndCancel() }

    func transcribe(_ pcm: Data, key: String) async throws -> String {
        guard !pcm.isEmpty, pcm.count <= 24_000 * 2 * 6, pcm.count.isMultiple(of: 2) else { throw VoiceFailure.protocolError }
        try Task.checkCancellation()
        let boundary = "MacTools-" + UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(Self.modelID)\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"reply.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(Self.wave(pcm)); append("\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await network.upload(for: request, from: body)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              data.count <= 16_384,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = result["text"] as? String, text.utf8.count <= 2_048 else { throw VoiceFailure.connection }
        return text
    }

    static func wave(_ pcm: Data) -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(UInt32(36 + pcm.count)); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
