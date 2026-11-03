import XCTest
@testable import ParcelKeeper

final class PendingShipmentWidgetTests: XCTestCase {
    private func ticket(_ status: ShipmentStatus = .inTransit, at time: TimeInterval = 0) -> Shipment {
        Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf", status: status,
                 createdAt: Date(timeIntervalSinceReferenceDate: time))
    }
    func testEligibilityAndStableOrdering() {
        let first = ticket(.exception, at: 1), second = ticket(.readyForPickup, at: 2)
        let values = [ticket(.delivered), second, ticket(.archived), first]
        XCTAssertEqual(PendingShipmentSelection.eligible(values).map(\.id), [first.id, second.id])
        XCTAssertEqual(PendingShipmentSelection.eligible([ticket(.outForDelivery)]).count, 1)
    }
    func testEmptyAndStaleSelectionFallback() {
        var data = PickupDataset(groups: [], records: [], shipments: [])
        XCTAssertNil(PendingShipmentSelection.selected(in: data))
        let first = ticket(); data.shipments = [first]
        data.pendingShipmentBrowsingID = UUID()
        XCTAssertEqual(PendingShipmentSelection.selected(in: data)?.id, first.id)
        data.shipments[0].status = .delivered
        XCTAssertNil(PendingShipmentSelection.selected(in: data))
    }
    func testBrowseWrapResetAndStaleButtonsPreserveShipments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("none"), containerURL: root)
        let first = ticket(at: 1), second = ticket(at: 2)
        try store.transaction { data in
            data.shipments = [first, second]
            let group = try XCTUnwrap(data.expressGroupID)
            data.records = [first, second].map {
                PickupRecord(groupID: group, code: $0.pickupCode, source: $0.note, shipmentID: $0.id)
            }
        }
        try store.browsePendingShipment(direction: 1, expectedID: first.id)
        XCTAssertEqual(PendingShipmentSelection.selected(in: try store.snapshot())?.id, second.id)
        XCTAssertThrowsError(try store.browsePendingShipment(direction: 1, expectedID: first.id))
        try store.browsePendingShipment(direction: 1, expectedID: second.id)
        XCTAssertEqual(PendingShipmentSelection.selected(in: try store.snapshot())?.id, first.id)
        try store.browsePendingShipment(direction: -1, expectedID: first.id)
        XCTAssertEqual(PendingShipmentSelection.selected(in: try store.snapshot())?.id, second.id)
        try store.resetPendingShipmentBrowsing(expected: .init(selectedID: second.id, browsing: true))
        XCTAssertNil(try store.snapshot().pendingShipmentBrowsingID)
        XCTAssertEqual(try store.snapshot().shipments, [first, second])
        XCTAssertThrowsError(try store.browsePendingShipment(direction: 0, expectedID: first.id))
    }
    func testOldDatasetAndPreferenceRoundTrip() throws {
        let old = Data(#"{"version":1,"groups":[],"records":[],"shipments":[]}"#.utf8)
        var data = try JSONDecoder().decode(PickupDataset.self, from: old)
        XCTAssertNil(data.pendingShipmentBrowsingID)
        data.pendingShipmentBrowsingID = UUID()
        XCTAssertEqual(try JSONDecoder().decode(PickupDataset.self, from: JSONEncoder().encode(data)), data)
    }
}
