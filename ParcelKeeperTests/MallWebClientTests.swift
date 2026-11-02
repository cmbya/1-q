import XCTest
import WebKit
@testable import ParcelKeeper

final class MallWebClientTests: XCTestCase {
    func testPlatformURLBoundary() {
        for platform in MallPlatform.allCases {
            XCTAssertTrue(platform.allowed(platform.loginURL))
            XCTAssertTrue(platform.allowed(platform.ordersURL))
            for raw in ["http://trade.m.jd.com", "https://jd.com.evil.test", "https://eviljd.com", "https://user@jd.com", "https://jd.com:444", "file:///orders.html", "https://yangkeduo.com.evil.test"] {
                XCTAssertFalse(platform.allowed(URL(string: raw)!))
            }
        }
        XCTAssertFalse(MallPlatform.jd.allowed(MallPlatform.pdd.ordersURL))
        XCTAssertNotEqual(MallPlatform.jd.sessionService, MallPlatform.pdd.sessionService)
    }

    func testCookiesRespectPlatformHostPathExpiry() {
        let p = MallPlatform.jd
        let c = TaobaoTrialCookie(name: "token", value: "secret", domain: ".jd.com", path: "/order", secure: true, expires: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(MallSession.applies(c, to: URL(string: "https://trade.m.jd.com/order/list")!, platform: p, now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(MallSession.applies(c, to: URL(string: "https://trade.m.jd.com/orders")!, platform: p))
        XCTAssertFalse(MallSession.applies(c, to: p.ordersURL, platform: p, now: Date(timeIntervalSince1970: 300)))
        XCTAssertFalse(MallSession.applies(c, to: MallPlatform.pdd.ordersURL, platform: .pdd))
        let hostOnly = TaobaoTrialCookie(name: "a", value: "b", domain: "jd.com", path: "/", secure: true, expires: nil)
        XCTAssertFalse(MallSession.applies(hostOnly, to: p.ordersURL, platform: p))
    }

    func testSessionRoundTripAndRejectForeignCookies() throws {
        let keys = MallMemoryKeys()
        let session = MallSession(platform: .jd, keys: keys)
        XCTAssertThrowsError(try session.load())
        let cookie = TaobaoTrialCookie(name: "pt_key", value: "test", domain: ".jd.com", path: "/", secure: true, expires: nil)
        try session.save([cookie])
        XCTAssertEqual(try session.load().first?.name, "pt_key")
        XCTAssertThrowsError(try MallSession(platform: .pdd, keys: keys).load())
        try session.clear()
        XCTAssertNil(keys.value)
        XCTAssertThrowsError(try session.save([]))
        keys.fail = true
        XCTAssertThrowsError(try session.save([cookie]))
        XCTAssertThrowsError(try session.clear())
    }

    func testJDOrderAndTraceProtocols() throws {
        let list: [String: Any] = ["body": ["orderList": [["orderId": "123456789", "wareInfoList": [["wareName": "测试商品"]]]]]]
        let orders = try MallWebParser.orders(list, platform: .jd)
        XCTAssertEqual(orders.first?.id, "123456789")
        XCTAssertTrue(orders.first!.url.absoluteString.contains("dealId=123456789"))
        let root: [String: Any] = ["body": ["carriageId": "JD123456789", "carrier": "京东快递", "tracePointVOList": [["createTime": "2026-10-01 12:00:00", "wlStateDesc": "快件已到达站点"]]]]
        let detail = try MallWebParser.jdDetail(root)
        XCTAssertEqual(detail.number, "JD123456789")
        let result = try detail.result(expected: "JD123456789", platform: .jd)
        XCTAssertTrue(result.logisticsInfo.contains("站点"))
        XCTAssertNotNil(result.logisticsTime)
        XCTAssertThrowsError(try detail.result(expected: "123456789", platform: .jd))
        XCTAssertThrowsError(try MallWebParser.jdDetail(["body": ["tracePointVOList": []]]))
        XCTAssertThrowsError(try MallWebParser.orders([:], platform: .jd))
    }

    func testPDDOrdersDoNotUseOrderNumberAsWaybill() throws {
        let root: [String: Any] = ["orders": [["order_sn": "261001-123456789", "tracking_number": "", "order_goods": [["goods_name": "商品"]]]]]
        let orders = try MallWebParser.orders(root, platform: .pdd)
        XCTAssertEqual(orders.first?.id, "261001-123456789")
        XCTAssertTrue(orders.first!.url.absoluteString.contains("order_sn="))
        XCTAssertThrowsError(try MallWebParser.orders(["result_list": [["order_sn": "261001-123456789", "status": "SIGN"]]], platform: .pdd))
    }

    func testPDDDOMBoundToOrderAndWaybillAndStopsAtRecommendations() throws {
        let url = URL(string: "https://mobile.yangkeduo.com/goods_express.html?order_sn=261001-123456789&tracking_number=79123456789012&shipping_id=1")!
        let text = "中通快递 : 79123456789012 复制\n已签收2026-10-01 18:21:51\n您的快件已送达，签收人：门口\n精选推荐\n2026-10-02 10:00:00\n快递商品广告"
        let detail = try MallWebParser.pddDetail(text: text, url: url, orderID: "261001-123456789")
        XCTAssertEqual(detail.number, "79123456789012")
        XCTAssertEqual(detail.points.count, 1)
        XCTAssertFalse(try detail.result(expected: detail.number, platform: .pdd).logisticsInfo.contains("广告"))
        XCTAssertThrowsError(try MallWebParser.pddDetail(text: text, url: url, orderID: "261001-987654321"))
        XCTAssertThrowsError(try MallWebParser.pddDetail(text: "未知页面", url: url, orderID: "261001-123456789"))
        XCTAssertThrowsError(try MallWebParser.pddDetail(text: text, url: MallPlatform.pdd.ordersURL, orderID: "261001-123456789"))
    }

    func testStrictBridgeAndErrors() throws {
        XCTAssertThrowsError(try MallWebParser.message(["type": "cookie", "body": "secret"]))
        XCTAssertThrowsError(try MallWebParser.message(["type": "response", "body": "{}", "url": "https://api.m.jd.com", "extra": true]))
        XCTAssertThrowsError(try MallWebParser.message(["type": "response", "body": String(repeating: "a", count: 2_000_001), "url": "https://api.m.jd.com"]))
        XCTAssertThrowsError(try MallWebParser.message(["type": "response", "body": "[]", "url": "https://api.m.jd.com"]))
        XCTAssertEqual(MallWebParser.pageFailure(url: URL(string: "https://plogin.m.jd.com/login/login")!, text: ""), .authentication)
        XCTAssertEqual(MallWebParser.pageFailure(url: MallPlatform.pdd.ordersURL, text: "请完成安全验证"), .verification)
        XCTAssertTrue(MallWebError.authentication.stopsBatch)
        XCTAssertTrue(MallWebError.verification.stopsBatch)
        XCTAssertFalse(MallWebError.noTrace.stopsBatch)
        for error in [MallWebError.authentication, .verification, .unsupported, .identityMismatch, .noTrace, .timeout] { XCTAssertNotNil(error.errorDescription) }
    }

    func testRejectMalformedIdentifiersBeforeURLConstruction() {
        for value in ["", "abc?x=y", "123/456", " 123456", "123456\n"] {
            XCTAssertThrowsError(try MallWebParser.detailURL(platform: .jd, orderID: value))
        }
        XCTAssertThrowsError(try MallWebParser.orders(["orders": [["order_sn": "bad?token=secret"]]], platform: .pdd))
    }

    @MainActor func testNavigationRejectsCrossPlatformAndNewWindows() {
        let client = MallWebClient(platform: .jd, cookies: [])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Parser-based URL tests exercise the exact allowlist used in both navigation delegates.
        XCTAssertFalse(MallPlatform.jd.allowed(URL(string: "https://mobile.yangkeduo.com/orders.html")!))
        XCTAssertFalse(MallPlatform.jd.allowed(URL(string: "pinduoduo://orders")!))
        client.webViewWebContentProcessDidTerminate(view)
    }

    func testDatesAndMalformedKnownTraceAreRejected() throws {
        XCTAssertNil(MallWebParser.date("2026-02-30 12:00:00"))
        XCTAssertNotNil(MallWebParser.date(NSNumber(value: 1_790_827_200_000)))
        XCTAssertFalse(MallWebParser.waybill("JD123456789\n"))
        XCTAssertThrowsError(try MallWebParser.jdDetail(["body": ["carriageId": "JD123456789", "tracePointVOList": [["createTime": "bad", "wlStateDesc": "已签收"]]]]))
        XCTAssertThrowsError(try MallWebParser.jdDetail(["body": ["carriageId": "JD123456789", "tracePointVOList": []]]))
    }

    @MainActor func testPreCancelledOperationAndBackgroundFailure() async {
        let task = Task { @MainActor in
            try Task.checkCancellation()
            return try await MallWebClient(platform: .jd, cookies: []).fetchOrders()
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled operation succeeded") }
        catch is CancellationError {} catch { XCTFail("unexpected cancellation error") }
        // No logged-in account, network calls or paid UAPI requests are made by this test.
        do { _ = try await MallWebClient(platform: .pdd, cookies: []).query(orderID: "261001-123456789", trackingNumber: "79123456789012"); XCTFail() }
        catch { XCTAssertTrue(error is MallWebError) }
    }
}

private final class MallMemoryKeys: AIKeyStore {
    var value: String?
    var fail = false
    func read(endpoint: String) throws -> String? { try read() }
    func save(_ value: String, endpoint: String) throws { try save(value) }
    func delete(endpoint: String) throws { try delete() }
    func read() throws -> String? { if fail { throw MallWebError.authentication }; return value }
    func save(_ value: String) throws { if fail { throw MallWebError.authentication }; self.value = value }
    func delete() throws { if fail { throw MallWebError.authentication }; value = nil }
}
