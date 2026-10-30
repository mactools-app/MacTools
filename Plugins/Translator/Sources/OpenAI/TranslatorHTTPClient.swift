import Foundation

protocol TranslatorHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: TranslatorHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url != nil else { throw OpenAICompatibleClientError.invalidResponse }
        let (data, response) = try await data(
            for: request,
            delegate: TranslatorRedirectDelegate()
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }

        return (data, httpResponse)
    }
}

final class TranslatorRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Redirected requests carry translation text and custom API-key headers.
        // Permit path changes only within the originally configured origin.
        guard let original = task.originalRequest, let origin = original.url,
              let target = request.url,
              target.user == nil, target.password == nil,
              target.scheme?.lowercased() == origin.scheme?.lowercased(),
              target.host?.lowercased() == origin.host?.lowercased(),
              effectivePort(target) == effectivePort(origin) else {
            completionHandler(nil)
            return
        }
        // URL loading can strip authentication even on a same-origin redirect.
        var redirect = request
        for header in ["Authorization", "api-key"] {
            redirect.setValue(original.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        completionHandler(redirect)
    }

    private func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
