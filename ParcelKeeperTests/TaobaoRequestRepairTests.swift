// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import XCTest
import CryptoKit
@testable import ParcelKeeper

final class TaobaoRequestRepairTests: XCTestCase {
    func testLogisticsRequestMatchesReferenceWithoutChangingOrderRequest() async throws {
        final class Network: AINetworking {
            var requests: [URLRequest] = []
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                requests.append(request)
                let root: [String: Any] = requests.count == 1
                    ? ["ret": ["SUCCESS"], "data": ["data": ["mainOrders": [["id": "12345678", "extra": ["tradeStatus": "WAIT_BUYER_CONFIRM_GOODS"]]]]]]
                    : ["ret": ["SUCCESS"], "data": ["mailNo": "SF1234567890123"]]
                return (try JSONSerialization.data(withJSONObject: root), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let network = Network()
        let cookie = TaobaoTrialCookie(name: "_m_h5_tk", value: "fixturetoken_999999", domain: ".taobao.com", path: "/", secure: true, expires: nil)
        _ = try await TaobaoTrialClient(cookies: [cookie], network: network).fetch()
        XCTAssertEqual(network.requests.count, 2)
        let order = network.requests[0], logistics = network.requests[1]
        XCTAssertEqual(order.value(forHTTPHeaderField: "Referer"), "https://main.m.taobao.com/")
        let orderQuery = URLComponents(url: order.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertFalse(orderQuery.contains(where: { $0.name == "preventFallback" }))
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: logistics.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        for (key, value) in ["jsv": "2.7.0", "needLogin": "true", "LoginRequest": "true", "ttid": "#t#ip##_h5_web_default", "preventFallback": "true", "timeout": "20000"] {
            XCTAssertEqual(query[key], value, key)
        }
        XCTAssertEqual(logistics.value(forHTTPHeaderField: "Referer"), "https://market.m.taobao.com/app/dinamic/pc-trade-logistics/home.html")
        let body = try JSONSerialization.jsonObject(with: Data(query["data"]!.utf8)) as! [String: String]
        XCTAssertEqual(body, ["orderId": "12345678"])
        let signed = "fixturetoken&\(query["t"]!)&12574478&\(query["data"]!)"
        let expected = Insecure.MD5.hash(data: Data(signed.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(query["sign"], expected)
    }
    func testUnknownBusinessCodeIsNotReportedAsSchemaFailure() {
        do { try TaobaoTrialParser.check(["ret": ["FAIL_BIZ_ORDER_NOT_FOUND::private"]]); XCTFail() }
        catch let error as TaobaoTrialError {
            XCTAssertTrue(error.localizedDescription.contains("业务请求未成功"))
        } catch { XCTFail() }
    }
    func testSafeUnknownCodeAndLogisticsShapeHidePrivateValues() {
        let root: [String: Any] = ["ret": ["FAIL_BIZ_ORDER_NOT_FOUND::private", "FAIL_TOKEN_123456789", "private"], "data": ["mailNo": "private"]]
        let message = TaobaoTrialDiagnostic(stage: "物流详情", reason: .shape, status: 200, root: root).localizedDescription
        XCTAssertTrue(message.contains("FAIL_BIZ_ORDER_NOT_FOUND"))
        XCTAssertFalse(message.contains("123456789"))
        XCTAssertFalse(message.contains("private"))
        XCTAssertFalse(message.contains("mainOrders"))
        XCTAssertTrue(message.contains("运单字段=是"))
    }
}
#endif
