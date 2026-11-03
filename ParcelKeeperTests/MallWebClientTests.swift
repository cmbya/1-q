import XCTest
import WebKit
@testable import ParcelKeeper

final class MallWebClientTests: XCTestCase {
    @MainActor func testPlatformBrowserContextSurvivesViewRecreationAndIsIsolated() {
        XCTAssertTrue(MallBrowserContext.store(for: .pdd) === MallBrowserContext.store(for: .pdd))
        XCTAssertFalse(MallBrowserContext.store(for: .pdd).isPersistent)
    }
    @MainActor func testClearingPDDBrowserContextReplacesOnlyItsStore() async {
        let pdd = MallBrowserContext.store(for: .pdd)
        await MallBrowserContext.clear(.pdd)
        XCTAssertFalse(pdd === MallBrowserContext.store(for: .pdd))
    }
    func testRequiredLoginCookiesAreNotAnalyticsCookies() {
        func cookie(_ name: String, domain: String) -> TaobaoTrialCookie {
            .init(name: name, value: "fixture", domain: domain, path: "/", secure: true, expires: nil)
        }
        XCTAssertFalse(MallSession.hasLoginCredentials([cookie("PDDAccessToken", domain: ".yangkeduo.com")], platform: .pdd))
        XCTAssertTrue(MallSession.hasLoginCredentials([cookie("PDDAccessToken", domain: ".yangkeduo.com"), cookie("pdd_user_id", domain: ".yangkeduo.com")], platform: .pdd))
        XCTAssertTrue(MallPlatform.pdd.loginURL.absoluteString.contains("_x_no_login_launch=1"))
    }
    func testPlatformURLBoundary() {
        for platform in MallPlatform.allCases {
            XCTAssertTrue(platform.allowed(platform.loginURL))
            XCTAssertTrue(platform.allowed(platform.ordersURL))
            for raw in ["http://trade.m.jd.com", "https://jd.com.evil.test", "https://eviljd.com", "https://user@jd.com", "https://jd.com:444", "file:///orders.html", "https://yangkeduo.com.evil.test"] {
                XCTAssertFalse(platform.allowed(URL(string: raw)!))
            }
        }
    }

    func testCookiesRespectPlatformHostPathExpiry() {
        let p = MallPlatform.pdd
        let c = TaobaoTrialCookie(name: "token", value: "secret", domain: ".yangkeduo.com", path: "/order", secure: true, expires: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(MallSession.applies(c, to: URL(string: "https://mobile.yangkeduo.com/order/list")!, platform: p, now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(MallSession.applies(c, to: URL(string: "https://mobile.yangkeduo.com/orders")!, platform: p))
        XCTAssertFalse(MallSession.applies(c, to: p.ordersURL, platform: p, now: Date(timeIntervalSince1970: 300)))
        XCTAssertFalse(MallSession.applies(c, to: URL(string: "https://trade.m.jd.com/order/list")!, platform: .pdd))
        let hostOnly = TaobaoTrialCookie(name: "a", value: "b", domain: "yangkeduo.com", path: "/", secure: true, expires: nil)
        XCTAssertFalse(MallSession.applies(hostOnly, to: p.ordersURL, platform: p))
    }

    func testSessionRoundTripAndRejectForeignCookies() throws {
        let keys = MallMemoryKeys()
        let session = MallSession(platform: .pdd, keys: keys)
        XCTAssertThrowsError(try session.load())
        let cookie = TaobaoTrialCookie(name: "PDDAccessToken", value: "test", domain: ".yangkeduo.com", path: "/", secure: true, expires: nil)
        let user = TaobaoTrialCookie(name: "pdd_user_id", value: "fixture", domain: ".yangkeduo.com", path: "/", secure: true, expires: nil)
        try session.save([cookie, user])
        XCTAssertEqual(try session.load().first?.name, "PDDAccessToken")
        XCTAssertThrowsError(try session.save([TaobaoTrialCookie(name: "foreign", value: "test", domain: ".jd.com", path: "/", secure: true, expires: nil)]))
        try session.clear()
        XCTAssertNil(keys.value)
        XCTAssertThrowsError(try session.save([]))
        keys.fail = true
        XCTAssertThrowsError(try session.save([cookie, user]))
        XCTAssertThrowsError(try session.clear())
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

    func testPageErrors() throws {
        XCTAssertEqual(MallWebParser.pageFailure(url: URL(string: "https://mobile.yangkeduo.com/login.html")!, text: ""), .authentication)
        XCTAssertEqual(MallWebParser.pageFailure(url: MallPlatform.pdd.ordersURL, text: "请完成安全验证"), .verification)
        XCTAssertTrue(MallWebError.authentication.stopsBatch)
        XCTAssertTrue(MallWebError.verification.stopsBatch)
        XCTAssertFalse(MallWebError.noTrace.stopsBatch)
        for error in [MallWebError.authentication, .verification, .unsupported, .identityMismatch, .noTrace, .timeout] { XCTAssertNotNil(error.errorDescription) }
    }

    func testRejectMalformedIdentifiersBeforeURLConstruction() {
        for value in ["", "abc?x=y", "123/456", " 123456", "123456\n"] {
            XCTAssertThrowsError(try MallWebParser.detailURL(platform: .pdd, orderID: value))
        }
        XCTAssertThrowsError(try MallWebParser.orders(["orders": [["order_sn": "bad?token=secret"]]], platform: .pdd))
    }

    func testDatesAndMalformedKnownTraceAreRejected() throws {
        XCTAssertNil(MallWebParser.date("2026-02-30 12:00:00"))
        XCTAssertNotNil(MallWebParser.date(NSNumber(value: 1_790_827_200_000)))
        XCTAssertFalse(MallWebParser.waybill("JD123456789\n"))
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
