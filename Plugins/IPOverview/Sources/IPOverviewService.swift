import Darwin
import Foundation
import MacToolsPluginKit

protocol IPOverviewProviding: Sendable {
    func collectSnapshot() async -> IPOverviewSnapshot
    func collectAddressSnapshot(preserving snapshot: IPOverviewSnapshot) async -> IPOverviewSnapshot
}

protocol IPOverviewHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: IPOverviewHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request, delegate: nil)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IPOverviewServiceError.invalidResponse
        }

        return (data, httpResponse)
    }
}

enum IPOverviewServiceError: LocalizedError {
    case invalidResponse
    case badStatus(Int)
    case invalidPayload
    case invalidIP(String)

    var errorDescription: String? {
        localizedDescription()
    }

    func localizedDescription(localization: PluginLocalization = PluginLocalization(bundle: .main)) -> String {
        switch self {
        case .invalidResponse:
            return localization.string("service.error.invalidResponse", defaultValue: "响应无效")
        case .badStatus(let statusCode):
            return "HTTP \(statusCode)"
        case .invalidPayload:
            return localization.string("service.error.invalidPayload", defaultValue: "数据格式不正确")
        case .invalidIP(let value):
            return localization.format("service.error.invalidIP", defaultValue: "IP 无效：%@", value)
        }
    }
}

struct IPOverviewService: IPOverviewProviding {
    private let httpClient: any IPOverviewHTTPClient
    private let timeout: TimeInterval
    private let localization: PluginLocalization

    init(
        httpClient: any IPOverviewHTTPClient = URLSession.shared,
        timeout: TimeInterval = 4,
        localization: PluginLocalization = PluginLocalization(bundle: .main)
    ) {
        self.httpClient = httpClient
        self.timeout = timeout
        self.localization = localization
    }

    func collectSnapshot() async -> IPOverviewSnapshot {
        async let localAddresses = Self.localAddresses()
        async let domesticIPv4Results = fetchPublicIP(route: .domestic, family: .ipv4)
        async let domesticIPv6Results = fetchPublicIP(route: .domestic, family: .ipv6)
        async let internationalIPv4Results = fetchPublicIP(route: .international, family: .ipv4)
        async let internationalIPv6Results = fetchPublicIP(route: .international, family: .ipv6)

        let local = await localAddresses
        let domesticIPv4 = await domesticIPv4Results
        let domesticIPv6 = await domesticIPv6Results
        let internationalIPv4 = await internationalIPv4Results
        let internationalIPv6 = await internationalIPv6Results
        let sourceResults = domesticIPv4.results
            + domesticIPv6.results
            + internationalIPv4.results
            + internationalIPv6.results
        let domesticIPv4Result = domesticIPv4.best
        let domesticIPv6Result = domesticIPv6.best
        let internationalIPv4Result = internationalIPv4.best
        let internationalIPv6Result = internationalIPv6.best

        var geoInfoByIP: [String: IPOverviewGeoInfo] = [:]
        for result in [
            domesticIPv4Result,
            domesticIPv6Result,
            internationalIPv4Result,
            internationalIPv6Result
        ].compactMap({ $0 }) {
            if let geoInfo = await fetchGeoInfo(ip: result.ip) {
                geoInfoByIP[result.ip] = geoInfo
            }
        }

        let errorMessage: String?
        if domesticIPv4Result == nil
            && domesticIPv6Result == nil
            && internationalIPv4Result == nil
            && internationalIPv6Result == nil {
            errorMessage = localization.string(
                "service.error.noPublicIP",
                defaultValue: "未能从外部检测源获取公网 IP"
            )
        } else {
            errorMessage = nil
        }

        return IPOverviewSnapshot(
            domesticIPv4: domesticIPv4Result,
            domesticIPv6: domesticIPv6Result,
            internationalIPv4: internationalIPv4Result,
            internationalIPv6: internationalIPv6Result,
            localAddresses: local,
            geoInfoByIP: geoInfoByIP,
            sourceResults: sourceResults,
            lastUpdated: Date(),
            errorMessage: errorMessage,
            isRefreshing: false
        )
    }

    func collectAddressSnapshot(preserving snapshot: IPOverviewSnapshot) async -> IPOverviewSnapshot {
        async let localAddresses = Self.localAddresses()
        async let domesticIPv4Result = fetchPreferredPublicIP(route: .domestic, family: .ipv4)
        async let internationalIPv4Result = fetchPreferredPublicIP(route: .international, family: .ipv4)

        let local = await localAddresses
        let refreshedDomesticIPv4 = await domesticIPv4Result
        let refreshedInternationalIPv4 = await internationalIPv4Result
        let refreshedPublicIP = refreshedDomesticIPv4 != nil || refreshedInternationalIPv4 != nil
        let publicIPs = Set([
            refreshedDomesticIPv4?.ip,
            refreshedInternationalIPv4?.ip,
            snapshot.domesticIPv6?.ip,
            snapshot.internationalIPv6?.ip
        ].compactMap(\.self))

        let errorMessage: String?
        if !refreshedPublicIP {
            errorMessage = localization.string(
                "service.error.noPublicIP",
                defaultValue: "未能从外部检测源获取公网 IP"
            )
        } else {
            errorMessage = nil
        }

        return IPOverviewSnapshot(
            domesticIPv4: refreshedDomesticIPv4,
            domesticIPv6: snapshot.domesticIPv6,
            internationalIPv4: refreshedInternationalIPv4,
            internationalIPv6: snapshot.internationalIPv6,
            localAddresses: local,
            geoInfoByIP: snapshot.geoInfoByIP.filter { publicIPs.contains($0.key) },
            sourceResults: snapshot.sourceResults,
            lastUpdated: refreshedPublicIP ? Date() : snapshot.lastUpdated,
            errorMessage: errorMessage,
            isRefreshing: false
        )
    }

    private func fetchPublicIP(
        route: IPOverviewEgressRoute,
        family: IPOverviewAddressFamily
    ) async -> (best: IPOverviewPublicIPResult?, results: [IPOverviewSourceResult]) {
        let sources = IPOverviewPublicIPSource.sources(route: route, family: family)
        let orderByID = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })

        let unorderedResults = await withTaskGroup(of: IPOverviewSourceResult.self) { group in
            for source in sources {
                group.addTask {
                    do {
                        let ip = try await fetchIP(from: source)
                        return IPOverviewSourceResult(
                            id: source.id,
                            family: family,
                            route: route,
                            source: source.name,
                            status: .success(ip)
                        )
                    } catch {
                        let message = (error as? IPOverviewServiceError)?
                            .localizedDescription(localization: localization)
                            ?? error.localizedDescription
                        return IPOverviewSourceResult(
                            id: source.id,
                            family: family,
                            route: route,
                            source: source.name,
                            status: .failure(message)
                        )
                    }
                }
            }

            var results: [IPOverviewSourceResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        let results = unorderedResults.sorted {
            (orderByID[$0.id] ?? Int.max) < (orderByID[$1.id] ?? Int.max)
        }
        let best = results.lazy.compactMap { sourceResult -> IPOverviewPublicIPResult? in
            guard case .success(let ip) = sourceResult.status else {
                return nil
            }

            return IPOverviewPublicIPResult(
                family: family,
                route: route,
                ip: ip,
                source: sourceResult.source
            )
        }.first

        return (best, results)
    }

    private func fetchPreferredPublicIP(
        route: IPOverviewEgressRoute,
        family: IPOverviewAddressFamily
    ) async -> IPOverviewPublicIPResult? {
        let lightweightTimeout = min(timeout, 0.75)
        let sources = IPOverviewPublicIPSource.sources(route: route, family: family).prefix(2)

        for source in sources {
            do {
                let ip = try await fetchIP(from: source, timeout: lightweightTimeout)
                return IPOverviewPublicIPResult(
                    family: family,
                    route: route,
                    ip: ip,
                    source: source.name
                )
            } catch {
                continue
            }
        }

        return nil
    }

    private func fetchIP(
        from source: IPOverviewPublicIPSource,
        timeout requestTimeout: TimeInterval? = nil
    ) async throws -> String {
        let (data, response) = try await fetch(source.url, timeout: requestTimeout)
        guard (200..<300).contains(response.statusCode) else {
            throw IPOverviewServiceError.badStatus(response.statusCode)
        }

        let ip: String?
        switch source.parser {
        case .jsonIP:
            ip = IPOverviewParser.ipFromJSON(data)
        case .cloudflareTrace:
            ip = IPOverviewParser.ipFromCloudflareTrace(data)
        case .plainText:
            ip = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .bilibiliIPService:
            ip = IPOverviewParser.ipFromBilibiliIPService(data)
        case .cipText:
            ip = IPOverviewParser.ipFromCIPText(data)
        case .ipipText:
            ip = IPOverviewParser.ipFromIPIPText(data)
        }

        guard let ip else {
            throw IPOverviewServiceError.invalidPayload
        }

        guard Self.isValidIPAddress(ip, family: source.family) else {
            throw IPOverviewServiceError.invalidIP(ip)
        }

        return ip
    }

    private func fetchGeoInfo(ip: String) async -> IPOverviewGeoInfo? {
        for source in IPOverviewGeoSource.allCases {
            do {
                let (data, response) = try await fetch(source.url(ip: ip))
                guard (200..<300).contains(response.statusCode) else {
                    continue
                }

                switch source {
                case .ipwhois:
                    if let info = IPOverviewParser.geoInfoFromIPWhois(data, ip: ip) {
                        return info
                    }
                case .ipapi:
                    if let info = IPOverviewParser.geoInfoFromIPAPI(data, ip: ip) {
                        return info
                    }
                case .internetdata:
                    if let info = IPOverviewParser.geoInfoFromInternetData(data, ip: ip) {
                        return info
                    }
                }
            } catch {
                continue
            }
        }

        return nil
    }

    private func fetch(
        _ url: URL,
        timeout requestTimeout: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout ?? timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("MacTools IP Overview", forHTTPHeaderField: "User-Agent")
        return try await httpClient.data(for: request)
    }

    static func localAddresses() -> [IPOverviewLocalAddress] {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return []
        }
        defer { freeifaddrs(interfaceAddresses) }

        var addresses: [IPOverviewLocalAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let currentPointer = pointer {
            defer { pointer = currentPointer.pointee.ifa_next }

            let name = String(cString: currentPointer.pointee.ifa_name)
            guard !isNoiseInterface(name),
                  (currentPointer.pointee.ifa_flags & UInt32(IFF_UP)) != 0,
                  let socketAddress = currentPointer.pointee.ifa_addr
            else {
                continue
            }

            let family: IPOverviewAddressFamily
            switch Int32(socketAddress.pointee.sa_family) {
            case AF_INET:
                family = .ipv4
            case AF_INET6:
                family = .ipv6
            default:
                continue
            }

            guard let address = numericAddress(from: socketAddress),
                  isUsableLocalAddress(address, family: family)
            else {
                continue
            }

            addresses.append(IPOverviewLocalAddress(
                id: "\(name)-\(address)",
                interfaceName: name,
                address: address,
                family: family
            ))
        }

        return addresses.sorted {
            if $0.interfaceName == $1.interfaceName {
                return $0.address < $1.address
            }

            return $0.interfaceName < $1.interfaceName
        }
    }

    static func isValidIPAddress(_ value: String, family: IPOverviewAddressFamily? = nil) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()

        switch family {
        case .ipv4:
            return inet_pton(AF_INET, value, &ipv4) == 1
        case .ipv6:
            return inet_pton(AF_INET6, value, &ipv6) == 1
        case nil:
            return inet_pton(AF_INET, value, &ipv4) == 1
                || inet_pton(AF_INET6, value, &ipv6) == 1
        }
    }

    private static func numericAddress(from pointer: UnsafePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(pointer.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        let nullIndex = host.firstIndex(of: 0) ?? host.endIndex
        let bytes = host[..<nullIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).nilIfEmpty
    }

    private static func isUsableLocalAddress(
        _ address: String,
        family: IPOverviewAddressFamily
    ) -> Bool {
        switch family {
        case .ipv4:
            return !address.hasPrefix("127.") && address != "0.0.0.0"
        case .ipv6:
            return !address.hasPrefix("::1")
                && !address.lowercased().hasPrefix("fe80")
        }
    }

    private static func isNoiseInterface(_ name: String) -> Bool {
        let lowercasedName = name.lowercased()
        let noisePrefixes = ["lo", "awdl", "utun", "llw", "bridge", "gif", "stf", "xhc", "anpi"]
        return noisePrefixes.contains { lowercasedName.hasPrefix($0) }
    }
}

struct IPOverviewPublicIPSource: Sendable {
    enum Parser: Sendable {
        case jsonIP
        case cloudflareTrace
        case plainText
        case bilibiliIPService
        case cipText
        case ipipText
    }

    let id: String
    let name: String
    let route: IPOverviewEgressRoute
    let family: IPOverviewAddressFamily
    let url: URL
    let parser: Parser

    static func sources(
        route: IPOverviewEgressRoute,
        family: IPOverviewAddressFamily
    ) -> [IPOverviewPublicIPSource] {
        switch (route, family) {
        case (.domestic, .ipv4):
            return [
                IPOverviewPublicIPSource(
                    id: "bilibili-v4",
                    name: "Bilibili IPv4",
                    route: .domestic,
                    family: .ipv4,
                    url: URL(string: "https://api.live.bilibili.com/ip_service/v1/ip_service/get_ip_addr")!,
                    parser: .bilibiliIPService
                ),
                IPOverviewPublicIPSource(
                    id: "cip-v4",
                    name: "cip.cc IPv4",
                    route: .domestic,
                    family: .ipv4,
                    url: URL(string: "https://cip.cc")!,
                    parser: .cipText
                ),
                IPOverviewPublicIPSource(
                    id: "ipip-v4",
                    name: "IPIP IPv4",
                    route: .domestic,
                    family: .ipv4,
                    url: URL(string: "https://myip.ipip.net")!,
                    parser: .ipipText
                ),
                IPOverviewPublicIPSource(
                    id: "netart-v4",
                    name: "NetArt IPv4",
                    route: .domestic,
                    family: .ipv4,
                    url: URL(string: "https://ipv4.netart.cn")!,
                    parser: .jsonIP
                )
            ]
        case (.domestic, .ipv6):
            return [
                IPOverviewPublicIPSource(
                    id: "ddnspod-v6",
                    name: "DNSPod IPv6",
                    route: .domestic,
                    family: .ipv6,
                    url: URL(string: "https://ipv6.ddnspod.com")!,
                    parser: .plainText
                ),
                IPOverviewPublicIPSource(
                    id: "netart-v6",
                    name: "NetArt IPv6",
                    route: .domestic,
                    family: .ipv6,
                    url: URL(string: "https://ipv6.netart.cn")!,
                    parser: .jsonIP
                )
            ]
        case (.international, .ipv4):
            return [
                IPOverviewPublicIPSource(
                    id: "ipcheck-v4-json",
                    name: "IPCheck.ing IPv4",
                    route: .international,
                    family: .ipv4,
                    url: URL(string: "https://4.ipcheck.ing")!,
                    parser: .jsonIP
                ),
                IPOverviewPublicIPSource(
                    id: "ipcheck-v4-trace",
                    name: "IPCheck.ing Trace IPv4",
                    route: .international,
                    family: .ipv4,
                    url: URL(string: "https://4.ipcheck.ing/cdn-cgi/trace")!,
                    parser: .cloudflareTrace
                ),
                IPOverviewPublicIPSource(
                    id: "ipify-v4",
                    name: "IPify IPv4",
                    route: .international,
                    family: .ipv4,
                    url: URL(string: "https://api4.ipify.org?format=json")!,
                    parser: .jsonIP
                ),
                IPOverviewPublicIPSource(
                    id: "ifconfig-v4",
                    name: "ifconfig.me IPv4",
                    route: .international,
                    family: .ipv4,
                    url: URL(string: "https://ifconfig.me/ip")!,
                    parser: .plainText
                )
            ]
        case (.international, .ipv6):
            return [
                IPOverviewPublicIPSource(
                    id: "ipcheck-v6-json",
                    name: "IPCheck.ing IPv6",
                    route: .international,
                    family: .ipv6,
                    url: URL(string: "https://6.ipcheck.ing")!,
                    parser: .jsonIP
                ),
                IPOverviewPublicIPSource(
                    id: "ipcheck-v6-trace",
                    name: "IPCheck.ing Trace IPv6",
                    route: .international,
                    family: .ipv6,
                    url: URL(string: "https://6.ipcheck.ing/cdn-cgi/trace")!,
                    parser: .cloudflareTrace
                ),
                IPOverviewPublicIPSource(
                    id: "ipify-v6",
                    name: "IPify IPv6",
                    route: .international,
                    family: .ipv6,
                    url: URL(string: "https://api6.ipify.org?format=json")!,
                    parser: .jsonIP
                )
            ]
        }
    }
}

enum IPOverviewGeoSource: CaseIterable {
    case ipwhois
    case ipapi
    case internetdata

    func url(ip: String) -> URL {
        switch self {
        case .ipwhois:
            return url(ip: ip, languageCode: IPOverviewLocale.geoLanguageCode())
        case .ipapi:
            return URL(string: "https://ipapi.co/\(ip)/json/")!
        case .internetdata:
            return URL(string: "https://api.internetdata.io/\(ip)")!
        }
    }

    func url(ip: String, languageCode: String?) -> URL {
        switch self {
        case .ipwhois:
            var components = URLComponents(string: "https://ipwho.is/\(ip)")!
            if let languageCode {
                components.queryItems = [URLQueryItem(name: "lang", value: languageCode)]
            }
            return components.url!
        case .ipapi:
            return URL(string: "https://ipapi.co/\(ip)/json/")!
        case .internetdata:
            return URL(string: "https://api.internetdata.io/\(ip)")!
        }
    }
}

enum IPOverviewLocale {
    static func geoLanguageCode() -> String? {
        let preferredLocalization = PluginRuntimeLocalization.preferredLanguages.first
            ?? Locale.current.identifier
        return geoLanguageCode(preferredLocalization: preferredLocalization)
    }

    static func geoLanguageCode(preferredLocalization: String) -> String? {
        let normalizedLocalization = preferredLocalization
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if normalizedLocalization.hasPrefix("zh") {
            return "zh-CN"
        }

        if normalizedLocalization.hasPrefix("en") {
            return "en"
        }

        return nil
    }
}

enum IPOverviewParser {
    static func ipFromJSON(_ data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ip = object["ip"] as? String
        else {
            return nil
        }

        return ip.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func ipFromCloudflareTrace(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
            .split(separator: "\n")
            .first { $0.hasPrefix("ip=") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }?
            .nilIfEmpty
    }

    static func ipFromBilibiliIPService(_ data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let data = object["data"] as? [String: Any],
            let ip = data["addr"] as? String
        else {
            return nil
        }

        return ip.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func ipFromCIPText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        return text
            .split(separator: "\n")
            .lazy
            .compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ip"
                else {
                    return nil
                }
                return String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            }
            .first
    }

    static func ipFromIPIPText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let pattern = #"(?:(?:当前\s*)?IP|Ip)\s*[：:]\s*([0-9A-Fa-f:.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func geoInfoFromIPWhois(_ data: Data, ip: String) -> IPOverviewGeoInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let success = object["success"] as? Bool, success == false {
            return nil
        }

        let connection = object["connection"] as? [String: Any]
        let timezone = object["timezone"] as? [String: Any]
        let asnValue = connection?["asn"].map { value in
            if let intValue = value as? Int {
                return "AS\(intValue)"
            }
            return "\(value)"
        }

        return IPOverviewGeoInfo(
            ip: ip,
            country: object["country"] as? String,
            countryCode: object["country_code"] as? String,
            region: object["region"] as? String,
            city: object["city"] as? String,
            isp: connection?["isp"] as? String,
            organization: connection?["org"] as? String,
            asn: asnValue,
            timezone: timezone?["id"] as? String,
            networkType: IPOverviewNetworkType.infer(
                organization: connection?["org"] as? String,
                isp: connection?["isp"] as? String,
                isHosting: nil
            ),
            isProxy: nil,
            isHosting: nil,
            source: "ipwho.is"
        )
    }

    static func geoInfoFromIPAPI(_ data: Data, ip: String) -> IPOverviewGeoInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if object["error"] as? Bool == true {
            return nil
        }

        let asn = object["asn"] as? String
        let organization = object["org"] as? String
        return IPOverviewGeoInfo(
            ip: ip,
            country: object["country_name"] as? String,
            countryCode: object["country_code"] as? String,
            region: object["region"] as? String,
            city: object["city"] as? String,
            isp: organization,
            organization: organization,
            asn: asn?.hasPrefix("AS") == true ? asn : asn.map { "AS\($0)" },
            timezone: object["timezone"] as? String,
            networkType: IPOverviewNetworkType.infer(
                organization: organization,
                isp: organization,
                isHosting: nil
            ),
            isProxy: nil,
            isHosting: nil,
            source: "ipapi.co"
        )
    }

    static func geoInfoFromInternetData(_ data: Data, ip: String) -> IPOverviewGeoInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let location = object["location"] as? [String: Any] else {
            return nil
        }

        let asn = object["asn"] as? [String: Any]
        let company = object["company"] as? [String: Any]
        let organization = asn?["name"] as? String
        let isp = company?["name"] as? String ?? organization
        let isHosting = (asn?["type"] as? String).map { $0 == "hosting" }
        return IPOverviewGeoInfo(
            ip: ip,
            country: location["country_name"] as? String,
            countryCode: location["country"] as? String,
            region: location["region"] as? String,
            city: location["city"] as? String,
            isp: isp,
            organization: organization,
            asn: (asn?["asn"] as? Int).map { "AS\($0)" },
            timezone: location["timezone"] as? String,
            networkType: IPOverviewNetworkType.infer(
                organization: organization,
                isp: isp,
                isHosting: isHosting
            ),
            isProxy: nil,
            isHosting: isHosting,
            source: "internetdata.io"
        )
    }
}
