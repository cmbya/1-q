import XCTest
@testable import ParcelKeeper

final class TaobaoTrialTests: XCTestCase {
    func testOrdersOnlyIncludeExplicitAwaitingReceipt() throws {
        let body: [String: Any] = ["ret": ["SUCCESS::调用成功"], "data": ["data": ["mainOrders": [
            ["id": "12345678", "extra": ["tradeStatus": "WAIT_BUYER_CONFIRM_GOODS"], "subOrders": [["itemInfo": ["title": "测试商品"]]]],
            ["id": "22345678", "extra": ["tradeStatus": "TRADE_FINISHED"]],
            ["id": "32345678", "statusInfo": ["text": "等待买家付款"]]
        ]]]]
        let result = try TaobaoTrialParser.orders(body)
        XCTAssertEqual(result.map(\.id), ["12345678"])
        XCTAssertEqual(result.first?.title, "测试商品")
    }
    func testAllWaybillsArePreservedNotOrderIDs() throws {
        let body: [String: Any] = ["ret": ["SUCCESS::调用成功"], "data": ["packages": [
            ["mailNo": "SF1234567890123", "companyName": "顺丰"],
            ["mailNo": "YT1234567890123", "companyName": "圆通"],
            ["orderId": "123456789012345678"]
        ]]]
        XCTAssertEqual(try TaobaoTrialParser.waybills(body).map(\.number).sorted(), ["SF1234567890123", "YT1234567890123"])
    }
    func testUnknownResponseIsFailureNotEmptySuccess() {
        XCTAssertThrowsError(try TaobaoTrialParser.orders(["ret": ["FAIL_SYS_SESSION_EXPIRED"]]))
        XCTAssertThrowsError(try TaobaoTrialParser.orders(["ret": ["SUCCESS"], "data": ["changed": true]]))
        XCTAssertThrowsError(try TaobaoTrialParser.waybills(["ret": ["FAIL_SYS_USER_VALIDATE"]]))
    }
    func testClientFetchesPreviewWithoutUAPIAndStopsOnValidation() async throws {
        final class Network: AINetworking {
            var requests: [URLRequest] = []
            var validation = false
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                requests.append(request)
                let object: [String: Any]
                if validation { object = ["ret": ["FAIL_SYS_USER_VALIDATE"]] }
                else if requests.count == 1 {
                    object = ["ret": ["SUCCESS"], "data": ["data": ["mainOrders": [
                        ["id": "12345678", "extra": ["tradeStatus": "WAIT_BUYER_CONFIRM_GOODS"]]
                    ]]]]
                } else {
                    object = ["ret": ["SUCCESS"], "data": ["mailNo": "SF1234567890123", "companyName": "顺丰"]]
                }
                return (try JSONSerialization.data(withJSONObject: object),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let network = Network()
        let client = TaobaoTrialClient(cookies: [], network: network)
        let report = try await client.fetch()
        XCTAssertEqual(report.candidates.map(\.number), ["SF1234567890123"])
        XCTAssertEqual(network.requests.count, 2)
        XCTAssertTrue(network.requests.allSatisfy { $0.url?.host == "h5api.m.taobao.com" })
        network.validation = true
        do { _ = try await TaobaoTrialClient(cookies: [], network: network).fetch(); XCTFail() }
        catch let error as TaobaoTrialDiagnostic {
            guard case .verification = error.reason else { return XCTFail("Expected verification failure") }
        }
        XCTAssertEqual(network.requests.count, 3)
    }
    func testSessionClearAndSecureStorageFailure() throws {
        let keys = TrackingRefreshTests.PhoneKeys()
        let session = TaobaoTrialSession(keys: keys)
        // This mock only implements endpoint credentials; legacy save is a no-op.
        XCTAssertThrowsError(try session.save([.init(name: "synthetic", value: "fixture", domain: ".taobao.com", path: "/", secure: true, expires: nil)]))
        try session.clear()
        XCTAssertThrowsError(try session.load())
    }
    func testCookieScopeAndUntrustedNavigation() {
        XCTAssertTrue(TaobaoTrialPolicy.allowed(URL(string: "https://login.m.taobao.com/login.htm")!))
        XCTAssertFalse(TaobaoTrialPolicy.allowed(URL(string: "https://taobao.com.evil.test/")!))
        XCTAssertFalse(TaobaoTrialPolicy.allowed(URL(string: "http://login.taobao.com/")!))
        let cookie = TaobaoTrialCookie(name: "synthetic", value: "fixture", domain: ".taobao.com", path: "/h5/", secure: true, expires: nil)
        XCTAssertTrue(cookie.applies(to: URL(string: "https://h5api.m.taobao.com/h5/test")!))
        XCTAssertFalse(cookie.applies(to: URL(string: "https://buyertrade.taobao.com/trade/")!))
        XCTAssertFalse(cookie.applies(to: URL(string: "https://evil.test/h5/test")!))
    }
}
