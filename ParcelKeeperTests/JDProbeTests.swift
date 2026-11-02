import XCTest
@testable import ParcelKeeper

final class JDProbeTests: XCTestCase {
    func testMissingProgressCanBeProbedButIsNotImportedAsAnOrderNumber() throws {
        let row: [String: Any] = ["orderId":"123456789012", "orderType":0,
            "orderStatusInfo":["originOrderStatus":7,"orderStatusName":"已完成"],
            "wareInfoList":[["skuId":"123456"]], "shopInfo":["shopId":"456789"]]
        let orders = try JDOrderSelection.probes(["body":["orderList":[row]]])
        XCTAssertEqual(orders.count, 1)
        XCTAssertTrue(orders[0].url.absoluteString.contains("dealState=7"))
        XCTAssertFalse(try JDOrderSelection.isRecentOrder(text: "已签收 2026-11-02", now: MallWebParser.date("2026-11-03 12:00")!))
        XCTAssertTrue(try JDOrderSelection.isRecentOrder(text: "下单时间：2026-11-02 10:00", now: MallWebParser.date("2026-11-03 12:00")!))
    }
    func testExplicitStoreToHomeIsExcluded() throws {
        let row: [String: Any] = ["orderId":"123456789012", "specialDealList":[["isStore2Home":true]]]
        XCTAssertTrue(try JDOrderSelection.probes(["body":["orderList":[row]]]).isEmpty)
    }
}
