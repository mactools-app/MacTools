import Foundation
import XCTest
@testable import TranslatorPlugin

final class TranslatorHTTPClientTests: XCTestCase {
    func testRedirectsKeepCredentialsAndBodyWithinOriginalOrigin() async throws {
        let cases: [(String, String, Bool)] = [
            ("http://10.0.0.10:8000/v1", "http://10.0.0.10:8000/gateway/v1", true),
            ("http://[fd12::1]/v1", "http://[fd12::1]:80/gateway/v1", true),
            ("https://gateway.example/v1", "https://GATEWAY.example:443/gateway/v1", true),
            ("http://10.0.0.10:8000/v1", "http://10.0.0.11:8000/v1", false),
            ("http://10.0.0.10:8000/v1", "http://10.0.0.10:8001/v1", false),
            ("http://10.0.0.10:8000/v1", "https://gateway.example/v1", false),
            ("http://10.0.0.10:8000/v1", "http://gateway.example/v1", false),
            ("https://gateway.example/v1", "http://gateway.example/v1", false),
            ("http://10.0.0.10/v1", "http://user:password@10.0.0.10/v1", false),
        ]
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        for (source, destination, allowed) in cases {
            let origin = try XCTUnwrap(URL(string: source))
            let delegate = TranslatorRedirectDelegate()
            var original = URLRequest(url: origin)
            original.httpMethod = "POST"
            original.httpBody = Data("private translation".utf8)
            original.setValue("Bearer fixture-key", forHTTPHeaderField: "Authorization")
            original.setValue("fixture-key", forHTTPHeaderField: "api-key")
            let task = session.dataTask(with: original)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: origin, statusCode: 307, httpVersion: nil, headerFields: ["Location": destination]
            ))
            var expected = original
            expected.url = try XCTUnwrap(URL(string: destination))
            var redirect = expected
            redirect.setValue(nil, forHTTPHeaderField: "Authorization")
            redirect.setValue(nil, forHTTPHeaderField: "api-key")

            let result = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                    newRequest: redirect) { continuation.resume(returning: $0) }
            }
            if allowed {
                XCTAssertEqual(result, expected, destination)
            } else {
                XCTAssertNil(result, destination)
            }
        }
    }
}
