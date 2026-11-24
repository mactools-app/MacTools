import Foundation
import XCTest
@testable import IPOverviewPlugin

final class IPOverviewParserTests: XCTestCase {
    func testParsesIPAddressFromJSONPayload() {
        let data = #"{"ip":"203.0.113.8"}"#.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromJSON(data), "203.0.113.8")
    }

    func testParsesIPAddressFromCloudflareTracePayload() {
        let data = """
        fl=123
        h=4.ipcheck.ing
        ip=2001:db8::1
        ts=1710000000
        """.data(using: .utf8)!

        XCTAssertEqual(IPOverviewParser.ipFromCloudflareTrace(data), "2001:db8::1")
    }

    func testParsesIPWhoisGeoPayload() {
        let data = """
        {
          "success": true,
          "country": "United States",
          "region": "California",
          "city": "Los Angeles",
          "connection": {
            "asn": 15169,
            "org": "Google LLC",
            "isp": "Google"
          },
          "timezone": {
            "id": "America/Los_Angeles"
          }
        }
        """.data(using: .utf8)!

        let info = IPOverviewParser.geoInfoFromIPWhois(data, ip: "8.8.8.8")

        XCTAssertEqual(info?.locationText, "United States / California / Los Angeles")
        XCTAssertEqual(info?.asn, "AS15169")
        XCTAssertEqual(info?.organization, "Google LLC")
        XCTAssertEqual(info?.timezone, "America/Los_Angeles")
    }

    func testParsesInternetDataGeoPayload() {
        let data = """
        {
          "ip": "8.8.8.8",
          "location": {
            "country": "US",
            "country_name": "United States",
            "timezone": "America/Los_Angeles"
          },
          "asn": {
            "asn": 15169,
            "name": "Google LLC",
            "type": "hosting"
          },
          "company": {
            "name": "Google LLC"
          }
        }
        """.data(using: .utf8)!

        let info = IPOverviewParser.geoInfoFromInternetData(data, ip: "8.8.8.8")

        XCTAssertEqual(info?.locationText, "United States")
        XCTAssertEqual(info?.countryCode, "US")
        XCTAssertEqual(info?.asn, "AS15169")
        XCTAssertEqual(info?.organization, "Google LLC")
        XCTAssertEqual(info?.timezone, "America/Los_Angeles")
        XCTAssertEqual(info?.isHosting, true)
        XCTAssertEqual(info?.networkType, .datacenter)
    }

    func testParsesIPAPIGeoPayload() {
        let data = """
        {
          "country_name": "United States",
          "region": "California",
          "city": "Mountain View",
          "org": "GOOGLE",
          "asn": "AS15169",
          "timezone": "America/Los_Angeles"
        }
        """.data(using: .utf8)!

        let info = IPOverviewParser.geoInfoFromIPAPI(data, ip: "8.8.8.8")

        XCTAssertEqual(info?.locationText, "United States / California / Mountain View")
        XCTAssertEqual(info?.networkText, "AS15169 GOOGLE")
        XCTAssertEqual(info?.source, "ipapi.co")
    }

    func testParsesNetworkQualityPayload() {
        let data = """
        {
          "base_rtt": 42.5,
          "dl_throughput": 125000000,
          "ul_throughput": 32000000,
          "dl_responsiveness": 80,
          "ul_responsiveness": 91.5,
          "dl_phase_duration": 4.2,
          "ul_phase_duration": 3.8,
          "interface_name": "en0",
          "test_endpoint": "example.apple.com",
          "start_date": "2026-06-24 18:02:05.338",
          "end_date": "2026-06-24 18:02:11.095"
        }
        """.data(using: .utf8)!

        let measurement = IPOverviewNetworkQualityParser.measurement(from: data)

        XCTAssertEqual(measurement?.baseRTTMilliseconds, 42.5)
        XCTAssertEqual(measurement?.downloadMbps, 125)
        XCTAssertEqual(measurement?.uploadMbps, 32)
        XCTAssertEqual(measurement?.uploadResponsivenessRPM, 91.5)
        XCTAssertEqual(measurement?.totalPhaseDuration, 8)
        XCTAssertEqual(measurement?.interfaceName, "en0")
        XCTAssertEqual(measurement?.testEndpoint, "example.apple.com")
    }

    func testValidatesIPAddressFamily() {
        XCTAssertTrue(IPOverviewService.isValidIPAddress("203.0.113.8", family: .ipv4))
        XCTAssertFalse(IPOverviewService.isValidIPAddress("203.0.113.8", family: .ipv6))
        XCTAssertTrue(IPOverviewService.isValidIPAddress("2001:db8::1", family: .ipv6))
        XCTAssertFalse(IPOverviewService.isValidIPAddress("not-an-ip"))
    }

    func testAddressSnapshotRefreshesLocalAddressesAndOnlyRequestsIPv4() async {
        let client = RecordingIPOverviewHTTPClient()
        let service = IPOverviewService(httpClient: client)
        let preservedSnapshot = IPOverviewSnapshot(
            domesticIPv4: nil,
            domesticIPv6: IPOverviewPublicIPResult(
                family: .ipv6,
                route: .domestic,
                ip: "2001:db8::8",
                source: "Cached Domestic IPv6"
            ),
            internationalIPv4: nil,
            internationalIPv6: IPOverviewPublicIPResult(
                family: .ipv6,
                route: .international,
                ip: "2001:db8::9",
                source: "Cached International IPv6"
            ),
            localAddresses: [
                IPOverviewLocalAddress(
                    id: "stale-192.0.2.1",
                    interfaceName: "stale",
                    address: "192.0.2.1",
                    family: .ipv4
                )
            ],
            geoInfoByIP: [:],
            sourceResults: [],
            lastUpdated: Date(),
            errorMessage: nil,
            isRefreshing: false
        )

        let snapshot = await service.collectAddressSnapshot(preserving: preservedSnapshot)
        let requestedURLs = await client.requestedURLs()

        XCTAssertEqual(snapshot.domesticIPv4?.ip, "198.51.100.8")
        XCTAssertEqual(snapshot.internationalIPv4?.ip, "203.0.113.8")
        XCTAssertEqual(snapshot.domesticIPv6?.ip, "2001:db8::8")
        XCTAssertEqual(snapshot.internationalIPv6?.ip, "2001:db8::9")
        XCTAssertFalse(snapshot.localAddresses.contains { $0.id == "stale-192.0.2.1" })
        XCTAssertEqual(requestedURLs.count, 2)
        XCTAssertEqual(
            Set(requestedURLs.compactMap(\.host)),
            ["api.live.bilibili.com", "4.ipcheck.ing"]
        )
    }

    func testAddressSnapshotClearsCachedPublicIPv4AndBoundsFallbackWorkWhenSourcesFail() async {
        let client = SelectiveIPOverviewHTTPClient(succeedsForDomesticPrimary: false)
        let service = IPOverviewService(httpClient: client)
        let preservedSnapshot = IPOverviewSnapshot(
            domesticIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .domestic,
                ip: "198.51.100.99",
                source: "Stale Domestic"
            ),
            domesticIPv6: nil,
            internationalIPv4: IPOverviewPublicIPResult(
                family: .ipv4,
                route: .international,
                ip: "203.0.113.99",
                source: "Stale International"
            ),
            internationalIPv6: nil,
            localAddresses: [],
            geoInfoByIP: [:],
            sourceResults: [],
            lastUpdated: Date(timeIntervalSinceReferenceDate: 1_000),
            errorMessage: nil,
            isRefreshing: false
        )

        let snapshot = await service.collectAddressSnapshot(preserving: preservedSnapshot)
        let requests = await client.recordedRequests()

        XCTAssertNil(snapshot.domesticIPv4)
        XCTAssertNil(snapshot.internationalIPv4)
        XCTAssertNotNil(snapshot.errorMessage)
        XCTAssertEqual(snapshot.lastUpdated, preservedSnapshot.lastUpdated)
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.timeoutInterval <= 0.75 })
        XCTAssertFalse(requests.contains { $0.url.host == "myip.ipip.net" })
        XCTAssertFalse(requests.contains { $0.url.host == "api4.ipify.org" })
    }
}

private actor RecordingIPOverviewHTTPClient: IPOverviewHTTPClient {
    private var urls: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        urls.append(url)
        let payload: String

        switch url.host {
        case "api.live.bilibili.com":
            payload = #"{"code":0,"data":{"addr":"198.51.100.8"}}"#
        case "cip.cc":
            payload = "IP : 198.51.100.8"
        case "myip.ipip.net":
            payload = "当前 IP：198.51.100.8"
        case "ipv4.netart.cn":
            payload = #"{"ip":"198.51.100.8"}"#
        case "4.ipcheck.ing" where url.path == "/cdn-cgi/trace":
            payload = "ip=203.0.113.8"
        case "4.ipcheck.ing", "api4.ipify.org":
            payload = #"{"ip":"203.0.113.8"}"#
        case "ifconfig.me":
            payload = "203.0.113.8"
        default:
            throw URLError(.unsupportedURL)
        }

        return (
            Data(payload.utf8),
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private actor SelectiveIPOverviewHTTPClient: IPOverviewHTTPClient {
    struct RecordedRequest: Sendable {
        let url: URL
        let timeoutInterval: TimeInterval
    }

    private let succeedsForDomesticPrimary: Bool
    private var requests: [RecordedRequest] = []

    init(succeedsForDomesticPrimary: Bool) {
        self.succeedsForDomesticPrimary = succeedsForDomesticPrimary
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        requests.append(RecordedRequest(url: url, timeoutInterval: request.timeoutInterval))

        guard succeedsForDomesticPrimary, url.host == "api.live.bilibili.com" else {
            throw URLError(.cannotConnectToHost)
        }

        return (
            Data(#"{"code":0,"data":{"addr":"198.51.100.8"}}"#.utf8),
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func recordedRequests() -> [RecordedRequest] {
        requests
    }
}
