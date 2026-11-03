import XCTest
@testable import ParcelKeeper

final class JDInAppClientTests: XCTestCase {
    private let orderID = "123456789012"
    private func list(_ rows: [[String: Any]]) -> [String: Any] {
        ["kind": "orders", "recognized": true, "orders": rows]
    }
    private func row(_ id: String = "123456789012", url: String? = nil) -> [String: Any] {
        ["id": id, "title": "合成测试商品", "status": "待收货", "url": url ?? "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(id)"]
    }
    private func parcel(_ number: String, time: Any = "2026-11-01 10:00:00", text: String = "已到达驿站，请取件") -> [String: Any] {
        ["number": number, "carrier": "京东快递", "points": [["time": time, "text": text]]]
    }
    private func detail(_ rows: [[String: Any]], order: String = "123456789012") -> [String: Any] {
        ["kind": "logistics", "recognized": true, "orderID": order, "parcels": rows]
    }
    func testCompletedOrdersAndMissingSubmitDatesRemainRecognizedWithoutPendingGate() throws {
        var completed = row(); completed["status"] = "已签收"; completed["submittedAt"] = "2026-10-15 12:00:00"
        var missing = row("123456789013"); missing["submittedAt"] = "not a date"
        let orders = try JDPageParser.orders(list([completed, missing]))
        XCTAssertNotNil(orders[0].submittedAt); XCTAssertFalse(orders[0].excluded)
        XCTAssertNil(orders[1].submittedAt)
        var report = JDOrderImportReport()
        let policy = JDOrderImportPolicy(now: JDOrderImportPolicy.submittedDate("2026-11-04")!)
        XCTAssertTrue(report.consider(submittedAt: orders[0].submittedAt, excluded: orders[0].excluded, policy: policy))
        XCTAssertFalse(report.consider(submittedAt: orders[1].submittedAt, excluded: orders[1].excluded, policy: policy))
        XCTAssertEqual(report.missingDate, 1)
    }
    func testMobileExplicitBusinessExclusionAndNoTitleBasedDeliveryGuess() throws {
        var physical = row(); physical["title"] = "服务机器人配送商品"; physical["status"] = "已完成"
        XCTAssertFalse(try JDPageParser.orders(list([physical]))[0].excluded)
        for label in ["外卖", "京东秒送", "虚拟服务"] {
            var excluded = row(); excluded["status"] = label
            XCTAssertTrue(try JDPageParser.orders(list([excluded]))[0].excluded)
        }
    }
    func testExplicitEmptyListIsDifferentFromUnknownSchema() throws {
        XCTAssertTrue(try JDPageParser.orders(list([])).isEmpty)
        let malformed: [[String: Any]] = [[:], ["orders": []], ["kind": "orders", "recognized": false, "orders": []]]
        for page in malformed {
            XCTAssertThrowsError(try JDPageParser.orders(page))
        }
        XCTAssertEqual(try JDPageParser.orders(list([row()])).first?.id, orderID)
        XCTAssertThrowsError(try JDPageParser.orders(list([row(), row()])))
    }
    func testOrderURLAndIdentifierCannotBeRepairedOrCrossPlatform() throws {
        for id in ["123456789012\n", " 123456789012", "abc123456"] {
            XCTAssertThrowsError(try JDPageParser.orders(list([row(id)])))
        }
        for url in ["http://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012",
                    "https://trade.m.jd.com.evil.test/order/deal_wuliu_jdm.shtml?dealId=123456789012",
                    "https://user@trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012",
                    "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=987654321000",
                    "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012&dealId=123456789012"] {
            XCTAssertThrowsError(try JDPageParser.orders(list([row(url: url)])))
        }
    }
    func testSplitOrderRequiresBothOrderAndWaybillAndKeepsSeparateNodes() throws {
        let parsed = try JDPageParser.parcels(detail([parcel("JD123456789"), parcel("SF123456789", text: "本人已取件")]), orderID: orderID)
        XCTAssertEqual(parsed.map(\.number), ["JD123456789", "SF123456789"])
        XCTAssertEqual(try parsed[1].result(expected: "SF123456789", platform: .jd).status, .delivered)
        XCTAssertThrowsError(try parsed[0].result(expected: "SF123456789", platform: .jd))
        XCTAssertThrowsError(try JDPageParser.parcels(detail([parcel("JD123456789")], order: "987654321000"), orderID: orderID))
        XCTAssertThrowsError(try JDPageParser.parcels(detail([parcel("JD123456789"), parcel("JD123456789")]), orderID: orderID))
        XCTAssertThrowsError(try JDPageParser.parcels(detail([parcel("")]), orderID: orderID))
    }
    func testMalformedTimesNoTraceAndFixedFailuresDoNotBecomeSuccess() throws {
        XCTAssertThrowsError(try JDPageParser.parcels(detail([parcel("JD123456789", time: "2026-02-30 10:00:00")]), orderID: orderID))
        let empty = try JDPageParser.parcels(detail([["number":"JD123456789", "carrier":"", "points": []]]), orderID: orderID)
        XCTAssertThrowsError(try empty[0].result(expected: "JD123456789", platform: .jd))
        for (code, error) in [("authentication", MallWebError.authentication), ("verification", .verification), ("identity", .identityMismatch)] {
            XCTAssertThrowsError(try JDPageParser.orders(["error":code])) { XCTAssertEqual($0 as? MallWebError, error) }
        }
    }
    func testSessionPreflightIsIsolatedAndDoesNotVerifyWebSession() throws {
        let cookies = ["pt_key", "pt_pin"].map { TaobaoTrialCookie(name: $0, value: "SYNTHETIC", domain: ".jd.com", path: "/", secure: true, expires: nil, httpOnly: true) }
        XCTAssertTrue(MallSession.hasLoginCredentials(cookies, platform: .jd))
        XCTAssertFalse(MallSession.hasLoginCredentials(cookies, platform: .pdd))
        XCTAssertFalse(MallSession.hasLoginCredentials(Array(cookies.prefix(1)), platform: .jd))
        XCTAssertThrowsError(try MallCookieImport.parse("pt_key=SYNTHETIC; pt_pin=SYNTHETIC", platform: .jd))
        XCTAssertNoThrow(try MallCookieImport.parse("thor=SYNTHETIC", platform: .jd))
        XCTAssertTrue(MallPlatform.jd.allowed(MallPlatform.jd.ordersURL))
        XCTAssertFalse(MallPlatform.jd.allowed(MallPlatform.pdd.ordersURL))
        XCTAssertNotEqual(MallPlatform.jd.sessionService, MallPlatform.pdd.sessionService)
    }
    func testJDBindingKeepsBackendDefaultAndExplicitPaidOverride() throws {
        var item = Shipment(trackingNumber: "JD123456789", carrierName: "京东快递", carrierCode: "jd", originPlatform: "jd", platformOrderID: orderID)
        item.backendBinding = .init(origin: "https://example.com", accountID: "a", orderID: "o", shipmentID: "s")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(item), "kdyzm")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(item, mode: .platformOnly), "kdyzm")
        item.refreshChannel = "uapi"
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(item), "uapi")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(item, mode: .platformOnly), "kdyzm")
        XCTAssertNotNil(item.backendBinding)
    }
    @MainActor func testJDAndPDDWebDataStoresNeverAlias() {
        XCTAssertFalse(MallBrowserContext.store(for: .jd) === MallBrowserContext.store(for: .pdd))
        XCTAssertFalse(MallBrowserContext.store(for: .jd).isPersistent)
    }
}
