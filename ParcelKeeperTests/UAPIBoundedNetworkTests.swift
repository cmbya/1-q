import XCTest
@testable import ParcelKeeper

/// No socket, account or query endpoint: URLProtocol produces synthetic bytes only.
final class UAPIBoundedNetworkTests: XCTestCase {
    final class Stream: URLProtocol {
        static var length: Int?
        static var size = 0
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bounded.invalid" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let headers = Self.length.map { ["Content-Length": String($0)] } ?? [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            var remaining = Self.size
            while remaining > 0 {
                let count = min(16384, remaining)
                client?.urlProtocol(self, didLoad: Data(repeating: 65, count: count))
                remaining -= count
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    let request = URLRequest(url: URL(string: "https://bounded.invalid/fixture")!)
    func testUnknownLengthAtLimitIsAcceptedAndCumulativeOverflowIsRejected() async throws {
        Stream.length = nil; Stream.size = UAPIBoundedNetwork.maximumResponseBytes
        let network = UAPIBoundedNetwork(protocolClasses: [Stream.self])
        let (data, _) = try await network.data(for: request)
        XCTAssertEqual(data.count, UAPIBoundedNetwork.maximumResponseBytes)
        Stream.size += 1
        do { _ = try await network.data(for: request); XCTFail("Unknown length overflow must fail") }
        catch { XCTAssertEqual(error as? UAPIError, .invalidResponse) }
    }
    func testOversizedDeclaredLengthIsRejectedEvenIfBodyIsEmpty() async throws {
        Stream.length = UAPIBoundedNetwork.maximumResponseBytes + 1; Stream.size = 0
        do { _ = try await UAPIBoundedNetwork(protocolClasses: [Stream.self]).data(for: request); XCTFail() }
        catch { XCTAssertEqual(error as? UAPIError, .invalidResponse) }
    }
    func testConfigurationDoesNotUseGlobalCookiesOrCache() {
        let configuration = UAPIBoundedNetwork.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
    func testRedirectIsRefusedForBothSameAndDifferentOrigins() {
        let network = UAPIBoundedNetwork()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        for location in ["https://bounded.invalid/next", "https://other.invalid/next"] {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": location])!
            var completed = false
            network.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: location)!)) {
                completed = true; XCTAssertNil($0)
            }
            XCTAssertTrue(completed)
        }
    }
}
