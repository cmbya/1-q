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
        var delivered = a; delivered.id = UUID(); delivered.status = .delivered
        XCTAssertEqual(ShipmentChoiceEntity.choices(in: [a, b, delivered]).map(\.id), [a.id])
        let choice = ShipmentChoiceEntity(a)
        XCTAssertEqual(choice.trackingNumber, a.trackingNumber)
        XCTAssertTrue(choice.summary.contains(a.note))
        XCTAssertTrue(choice.summary.contains(a.status.rawValue))
    }
}

extension TrackingRefreshTests {
    func testSelectedCompletedShipmentNeverQueriesOrSavesPhone() async throws {
        let client = Client()
        let keys = PhoneKeys()
        var service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        service.phones = ShipmentPhoneStore(keys: keys, cache: isolatedPhoneCache())
        let selectedNumber = shipment.trackingNumber
        for status in [ShipmentStatus.delivered, .archived] {
            try storage.transaction { data in
                data.shipments[0].status = status
                data.records[0].isCompleted = true
            }
            do {
                _ = try await service.refresh(id: shipment.id, phone: "0123",
                    expectedTrackingNumber: selectedNumber, pendingOnly: true)
                XCTFail("Completed selection must not dispatch")
            } catch ShipmentShortcutError.statusConflict {}
        }
        XCTAssertEqual(client.calls, 0)
        XCTAssertTrue(keys.values.isEmpty)
    }
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
