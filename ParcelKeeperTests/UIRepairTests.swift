import XCTest
import UserNotifications
@testable import ParcelKeeper

final class UIRepairTests: XCTestCase {
    func testPickupDeepLinkAcceptsOnlyCanonicalUUIDPath() throws {
        let id = UUID()
        for raw in [id.uuidString, id.uuidString.lowercased()] {
            XCTAssertEqual(PickupDeepLink.groupID(from: try XCTUnwrap(URL(string: "parcelkeeper://pickup/" + raw))), id)
        }
        for raw in [
            "https://pickup/\(id)", "parcelkeeper://train/\(id)",
            "parcelkeeper://pickup", "parcelkeeper://pickup/not-a-uuid",
            "parcelkeeper://pickup/{\(id)}", "parcelkeeper://pickup/\(id)/",
            "parcelkeeper://pickup/\(id)/extra", "parcelkeeper://pickup//\(id)",
            "parcelkeeper://pickup/\(id)?group=other", "parcelkeeper://pickup/\(id)?",
            "parcelkeeper://pickup/\(id)#other", "parcelkeeper://pickup/\(id)#",
            "parcelkeeper://user@pickup/\(id)", "parcelkeeper://pickup:123/\(id)",
            "parcelkeeper://pickup/%41\(id.uuidString.dropFirst())"
        ] {
            XCTAssertNil(PickupDeepLink.groupID(from: try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertTrue(PickupDeepLink.isRoot(try XCTUnwrap(URL(string: "parcelkeeper://pickup"))))
        XCTAssertFalse(PickupDeepLink.isRoot(try XCTUnwrap(URL(string: "parcelkeeper://pickup?group=bad"))))
    }

    // Policy-only test: never registers, requests authorization, schedules or
    // removes a real system notification. Source contract covers delegate wiring.
    func testForegroundPresentationRequestsBannerListAndSound() {
        XCTAssertEqual(NotificationManager.foregroundPresentationOptions, [.banner, .list, .sound])
    }

    @MainActor func testExternalReminderReloadPreservesManualPickupCompletionAndUnlocks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, containerURL: root)
        let store = ShipmentStore(storageProvider: { storage })
        let shipment = Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf", pickupCode: "A-123")
        try store.addThrowing(shipment)
        let record = try XCTUnwrap(store.pickupRecords.first { $0.shipmentID == shipment.id })
        try store.setPickupCompleted(id: record.id, completed: true, expected: record)
        let other = ShipmentStore(storageProvider: { storage })
        let date = Date().addingTimeInterval(3600)
        XCTAssertTrue(store.beginReminderOperation())
        try other.updateReminderThrowing(id: shipment.id, date: date)
        try store.reload()
        XCTAssertEqual(store.shipment(id: shipment.id)?.reminderDate, date)
        XCTAssertTrue(store.reminderOperationInProgress)
        XCTAssertTrue(try XCTUnwrap(store.pickupRecords.first { $0.id == record.id }).isCompleted)
        store.endReminderOperation()
        XCTAssertFalse(store.reminderOperationInProgress)
        try other.updateReminderThrowing(id: shipment.id, date: nil)
        try store.reload()
        XCTAssertNil(store.shipment(id: shipment.id)?.reminderDate)
        XCTAssertTrue(try XCTUnwrap(store.pickupRecords.first { $0.id == record.id }).isCompleted)
    }
}
