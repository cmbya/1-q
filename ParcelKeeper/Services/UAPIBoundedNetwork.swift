import Foundation

/// UAPI-only production transport: one request, ordinary system TLS, no shared
/// cookies/cache or redirects. Enforce the decoded response limit while receiving,
/// including unknown/chunked lengths; never buffer an unbounded data(for:) body.
final class UAPIBoundedNetwork: NSObject, AINetworking, URLSessionTaskDelegate {
    static let maximumResponseBytes = 2_000_000
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
        super.init()
    }
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return configuration
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = Self.configuration()
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            bytes.task.cancel()
            throw UAPIError.invalidResponse
        }
        var body = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < Self.maximumResponseBytes else { throw UAPIError.invalidResponse }
                body.append(byte)
            }
            try Task.checkCancellation()
        } catch {
            bytes.task.cancel()
            throw error
        }
        return (body, response)
    }
}
