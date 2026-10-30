import Foundation
import XCTest
@testable import TranslatorPlugin

@MainActor
final class OpenAICompatibleConfigurationTests: XCTestCase {
    func testEndpointNormalizationPreservesProviderPaths() throws {
        let cases = [
            ("https://api.openai.com", "https://api.openai.com/v1/chat/completions"),
            ("https://gateway.example.com/v1/", "https://gateway.example.com/v1/chat/completions"),
            ("https://gateway.example.com/openai/v1/chat/completions", "https://gateway.example.com/openai/v1/chat/completions"),
            ("https://provider.example.com/api/v4/chat/completions", "https://provider.example.com/api/v4/chat/completions"),
            ("http://10.0.0.10:8000/gateway/v1/chat/completions", "http://10.0.0.10:8000/gateway/v1/chat/completions"),
            ("http://[fd12:3456::1]:8000/gateway/v1/", "http://[fd12:3456::1]:8000/gateway/v1/chat/completions"),
        ]
        for (baseURL, expected) in cases {
            let configuration = OpenAICompatibleConfiguration(baseURL: baseURL)
            XCTAssertEqual(try configuration.endpointURL().absoluteString, expected, baseURL)
        }
    }

    func testEndpointRejectsInvalidOrInsecureConfiguration() {
        let cases: [(String, OpenAICompatibleConfiguration, OpenAICompatibleConfigurationError)] = [
            ("missing text placeholder", .init(promptTemplate: "Translate {{source_language}}"), .missingTextPlaceholder),
            ("blank URL", .init(baseURL: "  "), .blankBaseURL),
            ("missing host", .init(baseURL: "https:///v1"), .invalidBaseURL),
            ("malformed URL", .init(baseURL: "not-a-url"), .invalidBaseURL),
            ("unsupported scheme", .init(baseURL: "ftp://example.com"), .invalidBaseURL),
            ("insecure remote endpoint", .init(baseURL: "http://gateway.example.com"), .invalidBaseURL),
            ("blank model", .init(model: "  "), .blankModel),
        ]
        for (label, configuration, expected) in cases {
            XCTAssertEqual(configuration.validationError, expected, label)
            XCTAssertThrowsError(try configuration.endpointURL(), label) { error in
                XCTAssertEqual(error as? OpenAICompatibleConfigurationError, expected, label)
            }
        }
    }

    func testLoopbackHTTPBaseURLIsAllowedForLocalGateways() throws {
        for baseURL in ["http://localhost:11434", "http://127.0.0.1:11434", "http://[::1]:11434"] {
            let configuration = OpenAICompatibleConfiguration(baseURL: baseURL)
            XCTAssertNil(configuration.validationError, baseURL)
            XCTAssertTrue(try configuration.endpointURL().absoluteString.contains("/v1/chat/completions"), baseURL)
        }
    }

    func testHTTPAllowsOnlyPrivateLiteralAddressRanges() throws {
        let allowedHosts = [
            "10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
            "192.168.0.1", "192.168.255.254", "[fc00::1]", "[FD12:3456::1]",
        ]
        for host in allowedHosts {
            let configuration = OpenAICompatibleConfiguration(baseURL: "http://\(host):8000")
            XCTAssertNil(configuration.validationError, host)
            XCTAssertNoThrow(try configuration.endpointURL(), host)
        }

        let rejectedHosts = [
            "11.0.0.1", "172.15.255.254", "172.32.0.1", "192.169.0.1",
            "100.64.0.1", "169.254.1.1", "[fe80::1]", "[2001:db8::1]", "[::ffff:10.0.0.1]",
            "10.0.0.1.example.com", "gateway.local", "gateway", "10.1", "010.0.0.1", "0x0a000001",
        ]
        for host in rejectedHosts {
            let configuration = OpenAICompatibleConfiguration(baseURL: "http://\(host):8000")
            XCTAssertEqual(configuration.validationError, .invalidBaseURL, host)
            XCTAssertThrowsError(try configuration.endpointURL(), host)
        }
    }

    func testSaveTrimsBaseURLAndModelButPreservesPromptTemplate() {
        let storage = TranslatorInMemoryPluginStorage()
        let promptTemplate = "  翻译：{{text}}  "
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "  https://gateway.example.com/v1/  ",
            model: "  gpt-test  ",
            promptTemplate: promptTemplate
        )

        configuration.save(to: storage)

        XCTAssertEqual(storage.string(forKey: "translator.openai.base-url"), "https://gateway.example.com/v1/")
        XCTAssertEqual(storage.string(forKey: "translator.openai.model"), "gpt-test")
        XCTAssertEqual(storage.string(forKey: "translator.openai.prompt-template"), promptTemplate)
    }
}
