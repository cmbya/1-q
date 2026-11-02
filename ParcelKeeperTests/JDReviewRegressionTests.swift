import XCTest
@testable import ParcelKeeper

final class JDReviewRegressionTests: XCTestCase {
    func testRequestOwnershipDoesNotUseCurrentPage() throws {
        let body = "{\"orderId\":\"123456\"}"
        var c = URLComponents(string:"https://api.m.jd.com/api")!
        c.queryItems = [.init(name:"body", value:body)]
        XCTAssertEqual(MallWebParser.jdRequestOrderID(c.url!), "123456")
        c.queryItems!.append(.init(name:"orderId", value:"654321"))
        XCTAssertNil(MallWebParser.jdRequestOrderID(c.url!))
        XCTAssertNil(MallWebParser.jdRequestOrderID(URL(string:"https://api.m.jd.com/api?functionId=get_logistics_list_by_order_m")!))
    }
    func testNonCourierAndMalformedRowsDoNotEraseValidProbe() throws {
        let link = "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456"
        let excluded: [String: Any] = ["orderId":"654321", "progressInfo":["progressId":"store", "progressLink":link]]
        let valid: [String: Any] = ["orderId":"123456", "progressInfo":["progressId":"logistics", "progressLink":link]]
        XCTAssertEqual(try JDOrderSelection.probes(["body":["orderList":[["orderId":true],excluded,valid]]]).map(\.id), ["123456"])
    }
    func testConflictingLinkStillFailsClosed() {
        let row: [String: Any] = ["orderId":"123456", "progressInfo":["progressId":"logistics", "progressLink":"https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=654321"]]
        XCTAssertThrowsError(try JDOrderSelection.probes(["body":["orderList":[row]]]))
    }
    @MainActor func testEightFailuresDoNotStarveNinthOrder() async throws {
        let orders = (0..<30).map { MallWebOrder(id:String(123456+$0), title:"test", url:URL(string:"https://trade.m.jd.com")!) }
        let result = try await MallCandidateBatch.collect(orders:orders) { order in
            if order.id != orders[8].id { throw MallWebError.noTrace }
            return MallWebDetail(number:"JD123456789", carrier:"京东", points:[])
        }
        XCTAssertEqual(result.candidates.count,1)
        XCTAssertLessThanOrEqual(result.attempted,24)
    }
}