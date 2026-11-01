import XCTest
@testable import ParcelKeeper

final class ShipmentPresentationTests: XCTestCase {
    func testChineseTimeWithExplicitTimezone() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ShipmentDateDisplay.string(date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), "1970年1月1日 08:00")
        XCTAssertEqual(ShipmentDateDisplay.string(date, timeZone: TimeZone(secondsFromGMT: 0)!), "1970年1月1日 00:00")
    }
    func testShipmentChoicesExcludeArchivedAndShowDistinctDetails() {
        let a = Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf", note: "我的包裹")
        var b = a; b.id = UUID(); b.status = .archived
        XCTAssertEqual(ShipmentChoiceEntity.choices(in: [a, b]).map(\.id), [a.id])
        let choice = ShipmentChoiceEntity(a)
        XCTAssertEqual(choice.trackingNumber, a.trackingNumber)
        XCTAssertTrue(choice.summary.contains(a.note))
        XCTAssertTrue(choice.summary.contains(a.status.rawValue))
    }
}

extension TrackingRefreshTests {
    func testSelectedShipmentChangedNumberDoesNotQuery() async throws {
        let client = Client()
        let service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        do {
            _ = try await service.refresh(id: shipment.id, expectedTrackingNumber: "SF1234567890123")
            XCTFail("Changed selected ticket must not dispatch")
        } catch PickupStorageError.stalePreview {}
        XCTAssertEqual(client.calls, 0)
    }
}
