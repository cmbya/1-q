import XCTest
@testable import ParcelKeeper

final class JDWebRepairTests: XCTestCase {
    private let order = "123456789012"
    private func parse(_ text: String, orderID: String = "123456789012", url: URL? = nil) throws -> MallWebDetail {
        try MallWebParser.jdDOM(text: text, url: url ?? MallWebParser.detailURL(platform: .jd, orderID: orderID), orderID: orderID)
    }
    func testDescriptionBeforeTimestampKeepsCorrectNeighbor() throws {
        let detail = try parse("运单号：JD123456789\n国内承运人：京东物流\n包裹已签收\n2026-11-02 10:30:00\n包裹正在运输\n2026-11-01 08:00:00")
        XCTAssertEqual(detail.number, "JD123456789")
        XCTAssertEqual(detail.carrier, "京东物流")
        XCTAssertEqual(detail.points.map(\.text), ["包裹已签收", "包裹正在运输"])
        XCTAssertEqual(detail.points.first?.date, MallWebParser.date("2026-11-02 10:30:00"))
    }
    func testDescriptionAfterTimestampAndInline() throws {
        let detail = try parse("运单号\nJD123456789\n2026-11-02 10:30\n包裹已签收\n2026-11-01 08:00\n包裹正在运输")
        XCTAssertEqual(detail.points.map(\.text), ["包裹已签收", "包裹正在运输"])
        XCTAssertEqual(try parse("运单号：JD123456789\n2026-11-02 10:30 包裹已签收").points.first?.text, "包裹已签收")
    }
    func testAmbiguousNeighboringDescriptionsRejected() {
        XCTAssertThrowsError(try parse("运单号：JD123456789\n包裹已签收\n2026-11-02 10:30\n包裹正在运输"))
    }
    func testNoOrderIDSubstitutionOrMultiWaybill() {
        for text in ["订单编号：123456789012", "运单号：123456789012", "运单号：JD123456789\n运单号：SF123456789"] {
            XCTAssertThrowsError(try parse(text + "\n2026-11-02 10:30 包裹已签收"))
        }
    }
    func testNoTraceAndPartialDatesAreNotSuccess() {
        for text in ["运单号：JD123456789", "运单号：JD123456789\n11-02 10:30 包裹已签收", "运单号：JD123456789\n2026-02-30 10:30 包裹已签收"] {
            XCTAssertThrowsError(try parse(text))
        }
    }
    func testExactURLIdentityAndExpectedWaybill() throws {
        let text = "运单号：JD123456789\n2026-11-02 10:30 包裹已签收"
        for raw in ["https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=999999999999", "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789012&dealId=123456789012", "https://evil.example/order/deal_wuliu_jdm.shtml?dealId=123456789012"] {
            XCTAssertThrowsError(try parse(text, url: URL(string: raw)!))
        }
        XCTAssertThrowsError(try parse(text).result(expected: "SF123456789", platform: .jd))
    }
    func testExistingTraceAPIStillSupported() throws {
        let detail = try MallWebParser.jdDetail(["body": ["carriageId": "JD123456789", "tracePointVOList": [["createTime": "2026-11-02 10:30", "wlStateDesc": "包裹已签收"]]]])
        XCTAssertEqual(detail.points.first?.text, "包裹已签收")
    }
}
