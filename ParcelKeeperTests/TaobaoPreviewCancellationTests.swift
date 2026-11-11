// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import XCTest
@testable import ParcelKeeper

final class TaobaoPreviewCancellationTests: XCTestCase {
    private final class CancelNetwork: AINetworking {
        var calls = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            throw URLError(.cancelled)
        }
    }
    func testSystemCancellationPropagatesWithoutDiagnosticOrRetry() async {
        let network = CancelNetwork()
        do {
            _ = try await TaobaoTrialClient(cookies: [], network: network).fetch()
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Cancellation must not become network diagnostic") }
        XCTAssertEqual(network.calls, 1)
    }
}
#endif
