import XCTest
@testable import ParcelKeeper

final class ReviewIntegrationTests: XCTestCase {
    func testPublicJDEntryRoundTripsWithoutArbitraryTokens() throws {
        let raw = "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=123456789&dealState=7&orderType=0&skuid=1&shopid=2&token=private"
        let safe = try XCTUnwrap(Shipment.logisticsEntry(raw, orderID: "123456789"))
        XCTAssertFalse(safe.contains("token")); XCTAssertTrue(safe.contains("dealState=7"))
        var shipment = Shipment(trackingNumber: "JD123456789", carrierName: "京东", carrierCode: "jd")
        shipment.platformLogisticsURL = safe
        let restored = try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(shipment))
        XCTAssertEqual(restored.platformLogisticsURL, safe)
        XCTAssertNil(Shipment.logisticsEntry(raw, orderID: "987654321"))
        XCTAssertNil(Shipment.logisticsEntry(raw.replacingOccurrences(of: "trade.m.jd.com", with: "evil.test"), orderID: "123456789"))
    }
}
