import XCTest
@testable import ParcelKeeper

final class AuditLowRegressionTests: XCTestCase {
    private func withStore(_ body: (SharedPickupStore, Shipment, Shipment) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let first = Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf", createdAt: Date(timeIntervalSince1970: 1))
        let second = Shipment(trackingNumber: "SF2234567890123", carrierName: "顺丰", carrierCode: "sf", createdAt: Date(timeIntervalSince1970: 2))
        try store.transaction { data in
            data.shipments = [first, second]
            let group = try XCTUnwrap(data.expressGroupID)
            data.records = [first, second].map { PickupRecord(groupID: group, code: "", shipmentID: $0.id) }
        }
        try body(store, first, second)
    }
    func testStaleResetAndMissingLegacyIdentityLeaveNewPreferenceUntouched() throws {
        try withStore { store, first, second in
            try store.browsePendingShipment(direction: 1, expectedID: first.id)
            let old = PendingShipmentSelection.identity(in: try store.snapshot())
            try store.browsePendingShipment(direction: 1, expectedID: second.id)
            let before = try store.exportBackup()
            XCTAssertThrowsError(try store.resetPendingShipmentBrowsing(expected: old))
            XCTAssertThrowsError(try store.resetPendingShipmentBrowsing())
            XCTAssertEqual(try store.exportBackup(), before)
        }
    }
    func testAutomaticIdentityCannotResetManualChoiceOfSameSelectedShipment() throws {
        try withStore { store, first, second in
            let automatic = PendingShipmentSelection.identity(in: try store.snapshot())
            try store.browsePendingShipment(direction: 1, expectedID: first.id)
            try store.browsePendingShipment(direction: 1, expectedID: second.id)
            XCTAssertEqual(try store.snapshot().pendingShipmentBrowsingID, first.id)
            let before = try store.exportBackup()
            XCTAssertThrowsError(try store.resetPendingShipmentBrowsing(expected: automatic))
            XCTAssertEqual(try store.exportBackup(), before)
        }
    }
    func testCurrentResetPreservesBusinessDataAndBecomesAutomatic() throws {
        try withStore { store, first, _ in
            try store.browsePendingShipment(direction: 1, expectedID: first.id)
            let before = try store.snapshot()
            try store.resetPendingShipmentBrowsing(expected: PendingShipmentSelection.identity(in: before))
            let after = try store.snapshot()
            XCTAssertNil(after.pendingShipmentBrowsingID)
            XCTAssertEqual(after.shipments, before.shipments)
            XCTAssertEqual(after.records, before.records)
            XCTAssertEqual(PendingShipmentSelection.selected(in: after)?.id, first.id)
        }
    }
}
