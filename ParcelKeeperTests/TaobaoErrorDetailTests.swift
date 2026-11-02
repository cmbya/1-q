import XCTest
@testable import ParcelKeeper

final class TaobaoErrorDetailTests: XCTestCase {
    func testNetworkDetailsExcludeUnderlyingURLAndDescription() async throws {
        final class Network: AINetworking {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                throw NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: "secret-token", NSURLErrorFailingURLStringErrorKey: "https://example.test/?token=secret-token"])
            }
        }
        do { _ = try await TaobaoTrialClient(cookies: [], network: Network()).fetch(); XCTFail() }
        catch let error as TaobaoTrialDiagnostic {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("NSURLErrorDomain/-1001"))
            XCTAssertTrue(message.contains("mtop.taobao.order.queryboughtlistv2"))
            XCTAssertTrue(message.contains("尝试：1/2"))
            XCTAssertFalse(message.contains("secret-token"))
            XCTAssertFalse(message.contains("example.test"))
        }
    }
}
