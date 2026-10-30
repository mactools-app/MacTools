import Foundation
import XCTest
@testable import TranslatorPlugin

final class OpenAICompatibleClientTests: XCTestCase {
    func testBuildsPrivateHTTPRequestAndParsesSuccessResult() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubTranslatorHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "  你好  "),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)
        let languageSelection = TranslatorLanguageSelection(source: .english, target: .simplifiedChinese)
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "http://10.0.0.10:8000/gateway/v1/chat/completions",
            model: "gpt-test",
            promptTemplate: "Translate from {{source_language}} to {{target_language}}:\n{{text}}"
        )

        let result = try await client.translate(
            text: "Hello",
            languageSelection: languageSelection,
            configuration: configuration,
            apiKey: "test-key"
        )

        XCTAssertEqual(
            result,
            TranslationResult(
                providerTitle: "OpenAI 翻译",
                text: "你好",
                sourceText: "Hello",
                languageSelection: languageSelection
            )
        )

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://10.0.0.10:8000/gateway/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "test-key")

        let body = try Self.requestBody(from: request)
        XCTAssertEqual(body.model, "gpt-test")
        XCTAssertEqual(body.stream, false)
        XCTAssertEqual(body.temperature, 0.2, accuracy: 0.0001)
        XCTAssertEqual(body.messages.count, 1)
        XCTAssertEqual(body.messages.first?.role, "user")

        let prompt = try XCTUnwrap(body.messages.first?.content)
        XCTAssertTrue(prompt.contains("English"))
        XCTAssertTrue(prompt.contains("Simplified Chinese"))
        XCTAssertTrue(prompt.contains("Hello"))
    }

    func testModelIsTrimmedInRequest() async throws {
        let recorder = RequestRecorder()
        let httpClient = StubTranslatorHTTPClient(
            recorder: recorder,
            result: .success((
                Self.responsePayload(content: "Bonjour"),
                Self.httpResponse(statusCode: 200)
            ))
        )
        let client = OpenAICompatibleClient(httpClient: httpClient)
        let configuration = OpenAICompatibleConfiguration(model: "  gpt-trimmed  ")

        _ = try await client.translate(
            text: "Hello",
            languageSelection: TranslatorLanguageSelection(source: .english, target: .french),
            configuration: configuration,
            apiKey: "test-key"
        )

        let recordedRequests = await recorder.requests
        let request = try XCTUnwrap(recordedRequests.first)
        let body = try Self.requestBody(from: request)
        XCTAssertEqual(body.model, "gpt-trimmed")
    }

    func testSuccessResponseDoesNotRequireAssistantRole() async throws {
        let client = OpenAICompatibleClient(
            httpClient: StubTranslatorHTTPClient(
                recorder: RequestRecorder(),
                result: .success((
                    Self.responsePayload(content: "Hola"),
                    Self.httpResponse(statusCode: 200)
                ))
            )
        )

        let result = try await client.translate(
            text: "Hello",
            languageSelection: TranslatorLanguageSelection(source: .english, target: .spanish),
            configuration: OpenAICompatibleConfiguration(),
            apiKey: "test-key"
        )

        XCTAssertEqual(result.text, "Hola")
    }

    func testHTTP500MapsToRequestFailure() async {
        await assertTranslateError(
            result: .success((Data("{}".utf8), Self.httpResponse(statusCode: 500))),
            expectedDescription: "请求失败，请稍后重试"
        )
    }

    func testHTTP401MapsToUnauthorized() async {
        await assertTranslateError(
            result: .success((Data("{}".utf8), Self.httpResponse(statusCode: 401))),
            expectedDescription: "API Key 无效或无权限"
        )
    }

    func testHTTP403MapsToUnauthorized() async {
        await assertTranslateError(
            result: .success((Data("{}".utf8), Self.httpResponse(statusCode: 403))),
            expectedDescription: "API Key 无效或无权限"
        )
    }

    func testEmptyResponseContentMapsToEmptyResponse() async {
        await assertTranslateError(
            result: .success((
                Self.responsePayload(content: " \n\t "),
                Self.httpResponse(statusCode: 200)
            )),
            expectedDescription: "响应为空"
        )
    }

    func testMalformedPayloadMapsToParseFailure() async {
        await assertTranslateError(
            result: .success((Data(#"{"choices":[]}"#.utf8), Self.httpResponse(statusCode: 200))),
            expectedDescription: "无法解析翻译结果"
        )
    }

    func testTransportErrorMapsToRequestFailure() async {
        await assertTranslateError(
            result: .failure(URLError(.timedOut)),
            expectedDescription: "请求失败，请稍后重试"
        )
    }

    private static func responsePayload(content: String) -> Data {
        Data(
            """
            {
              "choices": [
                {
                  "message": {
                    "content": \(String(reflecting: content))
                  }
                }
              ]
            }
            """.utf8
        )
    }

    private static func httpResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func requestBody(from request: URLRequest) throws -> RequestBody {
        let data = try XCTUnwrap(request.httpBody)
        return try JSONDecoder().decode(RequestBody.self, from: data)
    }

    private func assertTranslateError(
        result: Result<(Data, HTTPURLResponse), Error>,
        expectedDescription: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let client = OpenAICompatibleClient(
            httpClient: StubTranslatorHTTPClient(
                recorder: RequestRecorder(),
                result: result
            )
        )

        do {
            _ = try await client.translate(
                text: "Hello",
                languageSelection: TranslatorLanguageSelection(source: .english, target: .simplifiedChinese),
                configuration: OpenAICompatibleConfiguration(),
                apiKey: "test-key"
            )
            XCTFail("Expected translate to throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, expectedDescription, file: file, line: line)
        }
    }
}

private actor RequestRecorder {
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        storedRequests
    }

    func record(_ request: URLRequest) {
        storedRequests.append(request)
    }
}

private struct StubTranslatorHTTPClient: TranslatorHTTPClient {
    let recorder: RequestRecorder
    let result: Result<(Data, HTTPURLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await recorder.record(request)
        return try result.get()
    }
}

private struct RequestBody: Decodable {
    struct Message: Decodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool
}
