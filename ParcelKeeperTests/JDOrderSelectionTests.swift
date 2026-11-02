import XCTest
@testable import ParcelKeeper

final class JDOrderSelectionTests: XCTestCase {
    private let id = "123456789012"
    func testUnknownTypeRequiresDOMEvenWhenNoDateWasChecked() throws {
        var unknown = item(); unknown.removeValue(forKey: "progressInfo")
        let report = try JDOrderSelection.inspect(root: root([unknown]), now: now)
        XCTAssertEqual(report.skipped[.unknownType], 1)
        XCTAssertNil(report.skipped[.unknownDate])
        XCTAssertTrue(report.requiresDOM)
    }
    func testKnownEmptyAndExplicitNonCourierDoNotRequireDOM() throws {
        XCTAssertFalse(try JDOrderSelection.inspect(root: root([]), now: now).requiresDOM)
        var instant = item(); instant["progressInfo"] = ["progressId": "store2home"]
        XCTAssertFalse(try JDOrderSelection.inspect(root: root([instant]), now: now).requiresDOM)
    }
    func testSignedRecentDOMRemainsEligibleAfterUnknownAPIType() throws {
        var unknown = item(); unknown.removeValue(forKey: "progressInfo")
        XCTAssertTrue(try JDOrderSelection.inspect(root: root([unknown]), now: now).requiresDOM)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(), now: now).first?.id, id)
    }
    private var now: Date { MallWebParser.date("2026-11-02 12:00:00")! }
    private func item(_ link: String? = nil) -> [String: Any] {
        ["orderId": id, "progressInfo": ["progressId": "logistics", "progressLink": link ?? "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012&orderType=0&skuid=456&shopid=789&dealState=7"],
         "orderStatusInfo": ["orderStatusName": "已完成"], "wareInfoList": [["wareName": "咖啡"]]]
    }
    private func root(_ items: [[String: Any]]) -> [String: Any] { ["body": ["orderList": items]] }
    private func snapshot(date: String = "2026-10-02 12:00:00", text: String? = nil) -> [String: Any] {
        ["recognized": true, "empty": false, "rows": [["id": id, "url": "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012&orderType=0", "text": text ?? "订单编号：123456789012\n下单时间：\(date)\n已签收", "title": "咖啡", "orderDate": date]]]
    }
    func testExactEnvelopeAndKnownEmpty() throws {
        XCTAssertThrowsError(try JDOrderSelection.orders(root: ["orderList": []], now: now))
        XCTAssertEqual(try JDOrderSelection.orders(root: root([]), now: now).count, 0)
        XCTAssertThrowsError(try JDOrderSelection.ordersDOM(["rows": []], now: now))
        XCTAssertThrowsError(try JDOrderSelection.ordersDOM(["recognized": true, "empty": false, "rows": []], now: now))
        XCTAssertTrue(try JDOrderSelection.ordersDOM(["recognized": true, "empty": true, "rows": []], now: now).isEmpty)
    }
    func testOriginalURLPreservedAndDeliveredIncluded() throws {
        let link = "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)&orderType=0&skuid=42&shopid=99&dealState=7&source=m_inner_orderList.track_orderTrack"
        let orders = try JDOrderSelection.orders(root: root([item(link)]), now: now, recentMonth: false)
        XCTAssertEqual(orders.first?.url.absoluteString, link)
        XCTAssertEqual(orders.first?.id, id)
        XCTAssertEqual(try JDOrderSelection.orders(root: root([item("//trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)")]), now: now, recentMonth: false).count, 1)
        XCTAssertEqual(try JDOrderSelection.orders(root: root([item("/order/deal_wuliu_jdm.shtml?dealId=\(id)")]), now: now, recentMonth: false).count, 1)
    }
    func testDuplicateAndInvalidJSONIdentityRejected() {
        XCTAssertThrowsError(try JDOrderSelection.orders(root: root([item(), item()]), now: now, recentMonth: false))
        var invalid = item(); invalid["orderId"] = "123&dealId=999999"
        XCTAssertThrowsError(try JDOrderSelection.orders(root: root([invalid]), now: now, recentMonth: false))
    }
    func testPoisonedURLsRejected() {
        for link in ["https://evil.com/order/deal_wuliu_jdm.shtml?dealId=\(id)", "https://trade.m.jd.com.evil.com/order/deal_wuliu_jdm.shtml?dealId=\(id)", "http://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)", "https://user@trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)", "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)&dealId=\(id)", "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=999999", "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)&orderID=999999"] {
            XCTAssertThrowsError(try JDOrderSelection.orders(root: root([item(link)]), now: now, recentMonth: false), link)
        }
    }
    func testWhitelistNotProductNameOrPendingFilter() throws {
        var unknown = item(); unknown.removeValue(forKey: "progressInfo")
        var instant = item(); instant["orderId"] = "234567890123"; instant["progressInfo"] = ["progressId": "store2home"]
        var cancelled = item(); cancelled["orderId"] = "345678901234"; cancelled["orderStatusInfo"] = ["orderStatusName": "已取消"]
        XCTAssertEqual(try JDOrderSelection.orders(root: root([unknown, instant, cancelled]), now: now, recentMonth: false).count, 0)
        let report = try JDOrderSelection.inspect(root: root([unknown, instant]), now: now)
        XCTAssertEqual(report.skipped[.unknownType], 1)
        XCTAssertEqual(report.skipped[.nonCourier], 1)
    }
    func testUnknownJSONDateDoesNotBroadenRecentScope() throws {
        var row = item(); row["createTime"] = "2026-11-01 12:00:00"
        let report = try JDOrderSelection.inspect(root: root([row]), now: now)
        XCTAssertTrue(report.orders.isEmpty)
        XCTAssertEqual(report.skipped[.unknownDate], 1)
        XCTAssertEqual(try JDOrderSelection.orders(root: root([row]), now: now, recentMonth: false).count, 1)
    }
    func testEvidenceBasedMissingLinkFallback() throws {
        var row = item(); row["progressInfo"] = ["progressId": "logistics"]
        XCTAssertTrue(try JDOrderSelection.orders(root: root([row]), now: now, recentMonth: false).isEmpty)
        row["orderStatusInfo"] = ["originOrderStatus": "7", "orderStatusName": "已完成"]
        row["orderType"] = "0"; row["shopInfo"] = ["shopId": "89"]
        row["wareInfoList"] = [["skuId": "42", "wareName": "咖啡"]]
        let url = try XCTUnwrap(JDOrderSelection.orders(root: root([row]), now: now, recentMonth: false).first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "dealState", value: "7")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "skuid", value: "42")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "shopid", value: "89")))
    }
    func testDOMMonthInclusiveAndFutureExcluded() throws {
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(), now: now).count, 1)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(date: "2026-10-02 11:59:59"), now: now).count, 0)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(date: "2026-11-02 12:00:00"), now: now).count, 1)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(date: "2026-11-02 12:00:01"), now: now).count, 0)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(date: ""), now: now).count, 0)
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(date: "2026-11-01", text: "订单编号：123456789012\n下单日期：2026-11-01\n已完成"), now: now).count, 1)
    }
    func testDOMRejectsMixedIdentityAndUnlabeledDate() throws {
        XCTAssertThrowsError(try JDOrderSelection.ordersDOM(snapshot(text: "订单编号：999999\n下单时间：2026-10-02 12:00:00"), now: now))
        XCTAssertThrowsError(try JDOrderSelection.ordersDOM(snapshot(text: "订单编号：123456789012\n订单编号：999999\n下单时间：2026-10-02 12:00:00"), now: now))
        XCTAssertEqual(try JDOrderSelection.ordersDOM(snapshot(text: "订单编号：123456789012\n签收时间：2026-10-02 12:00:00"), now: now).count, 0)
        var duplicate = snapshot(); let rows = duplicate["rows"] as! [[String: Any]]; duplicate["rows"] = rows + rows
        XCTAssertThrowsError(try JDOrderSelection.ordersDOM(duplicate, now: now))
    }
}
