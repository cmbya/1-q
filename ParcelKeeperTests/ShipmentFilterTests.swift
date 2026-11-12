import XCTest
@testable import ParcelKeeper

final class ShipmentFilterTests: XCTestCase {
    private func makeShipment(_ status: ShipmentStatus) -> Shipment {
        Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yuantong", status: status)
    }

    func testReadyForPickupBelongsToPickupFilterOnly() {
        let pickup = makeShipment(.readyForPickup)
        XCTAssertFalse(ShipmentFilter.active.includes(pickup))
        XCTAssertTrue(ShipmentFilter.pickup.includes(pickup))
    }

    func testActiveFilterKeepsUnfinishedShipments() {
        for status in [ShipmentStatus.inTransit, .outForDelivery, .exception] {
            XCTAssertTrue(ShipmentFilter.active.includes(makeShipment(status)), status.rawValue)
        }
    }

    func testDeliveredShipmentLeavesActiveFilter() {
        let delivered = makeShipment(.delivered)
        XCTAssertFalse(ShipmentFilter.active.includes(delivered))
        XCTAssertTrue(ShipmentFilter.delivered.includes(delivered))
    }

    func testDeliveredShipmentWithPendingReceiptStaysActive() {
        var delivered = makeShipment(.delivered)
        delivered.homeDelivery = true
        XCTAssertTrue(delivered.needsReceiptConfirmation)
        XCTAssertTrue(ShipmentFilter.active.includes(delivered))
        XCTAssertFalse(ShipmentFilter.delivered.includes(delivered))
    }

    func testArchivedShipmentIsExcludedFromStatusFilters() {
        let archived = makeShipment(.archived)
        XCTAssertFalse(ShipmentFilter.active.includes(archived))
        XCTAssertFalse(ShipmentFilter.pickup.includes(archived))
        XCTAssertFalse(ShipmentFilter.delivered.includes(archived))
        XCTAssertTrue(ShipmentFilter.all.includes(archived))
    }
}
