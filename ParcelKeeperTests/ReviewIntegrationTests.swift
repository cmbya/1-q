import XCTest
@testable import ParcelKeeper

final class ReviewIntegrationTests: XCTestCase {
    func testLegacyMetadataRoundTripsWithoutExecutableConnector() throws {
        var shipment = Shipment(trackingNumber: "YT123456789", carrierName: "圆通", carrierCode: "yto")
        shipment.platformLogisticsURL = "https://example.invalid/legacy-order"
        shipment.originPlatform = "removed_market"
        let restored = try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(shipment))
        XCTAssertEqual(restored, shipment)
        XCTAssertThrowsError(try TrackingRefreshService.resolvedChannel(restored))
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(restored, mode: .uapi), "uapi")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(restored, mode: .tmini), "tmini")
    }
}
