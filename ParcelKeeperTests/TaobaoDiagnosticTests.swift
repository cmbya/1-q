import XCTest
@testable import ParcelKeeper

final class TaobaoDiagnosticTests: XCTestCase {
    func testOnlyWhitelistedMetadataIsDisplayed() {
        let secret = "synthetic-private-value"
        let root: [String: Any] = ["ret": ["FAIL_SYS_ILLEGAL_ACCESS::" + secret, secret],
            "data": ["mainOrders": [], secret: secret]]
        let message = TaobaoTrialDiagnostic(stage: "订单列表", reason: .shape, status: 200, root: root).localizedDescription
        XCTAssertTrue(message.contains("订单列表"))
        XCTAssertTrue(message.contains("HTTP 200"))
        XCTAssertTrue(message.contains("FAIL_SYS_ILLEGAL_ACCESS"))
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains("data.mainOrders=是"))
    }
    func testClientReportsStageAndResponseKind() async throws {
        final class Network: AINetworking {
            var body = Data("<html>private content</html>".utf8)
            var status = 200
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let network = Network()
        for (status, marker) in [(200, "非JSON"), (403, "HTTP 403")] {
            network.status = status
            do { _ = try await TaobaoTrialClient(cookies: [], network: network).fetch(); XCTFail() }
            catch let error as TaobaoTrialDiagnostic {
                XCTAssertTrue(error.localizedDescription.contains("订单列表"))
                XCTAssertTrue(error.localizedDescription.contains(marker))
                XCTAssertFalse(error.localizedDescription.contains("private content"))
            }
        }
        network.status = 200
        network.body = try JSONSerialization.data(withJSONObject: ["ret": ["SUCCESS"], "data": ["changed": true]])
        do { _ = try await TaobaoTrialClient(cookies: [], network: network).fetch(); XCTFail() }
        catch let error as TaobaoTrialDiagnostic {
            XCTAssertTrue(error.localizedDescription.contains("data.data.mainOrders=否"))
        }
    }
    func testSessionFailureAndLogisticsStage() async throws {
        final class Network: AINetworking {
            var calls = 0
            var hasOrder = false
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                calls += 1
                let root: [String: Any]
                if hasOrder && calls == 1 {
                    root = ["ret": ["SUCCESS"], "data": ["data": ["mainOrders": [["id": "12345678", "extra": ["tradeStatus": "WAIT_BUYER_CONFIRM_GOODS"]]]]]]
                } else { root = ["ret": ["FAIL_SYS_SESSION_EXPIRED::private"], "data": [:]] }
                return (try JSONSerialization.data(withJSONObject: root), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        for hasOrder in [false, true] {
            let network = Network(); network.hasOrder = hasOrder
            do { _ = try await TaobaoTrialClient(cookies: [], network: network).fetch(); XCTFail() }
            catch let error as TaobaoTrialDiagnostic {
                guard case .login = error.reason else { return XCTFail("Expected login failure") }
                XCTAssertTrue(error.localizedDescription.contains(hasOrder ? "物流详情" : "订单列表"))
                XCTAssertTrue(error.localizedDescription.contains("FAIL_SYS_SESSION_EXPIRED"))
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
            XCTAssertEqual(network.calls, hasOrder ? 2 : 1)
        }
    }
    func testBlockedDestinationHidesCredentialsAndParameters() {
        let url = URL(string: "https://private-user:secret@passport.example.test/path?token=secret")!
        let text = TaobaoTrialPolicy.blockedDestination(url)
        XCTAssertEqual(text, "https://passport.example.test")
        XCTAssertFalse(text.contains("secret"))
        XCTAssertEqual(TaobaoTrialPolicy.blockedDestination(URL(string: "taobao://private/path?token=secret")!), "taobao://（外部App）")
    }
}
