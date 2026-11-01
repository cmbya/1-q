import XCTest
@testable import ParcelKeeper

@MainActor
final class LifecycleRepairTests: XCTestCase {
    private var root: URL!
    private var storage: SharedPickupStore!
    private var store: ShipmentStore!
    private var keys: TrackingRefreshTests.PhoneKeys!
    private var reloads: [String] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        keys = TrackingRefreshTests.PhoneKeys()
        store = ShipmentStore(storageProvider: { self.storage })
        store.shipmentPhones = ShipmentPhoneStore(keys: keys)
        store.reloadWidget = { self.reloads.append($0) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func add(_ number: String) throws -> Shipment {
        let value = Shipment(trackingNumber: number, carrierName: "顺丰", carrierCode: "sf")
        try store.addThrowing(value)
        return value
    }
    func testManualChangesAndImportReloadPendingWidget() throws {
        let value = try add("SF1234567890123")
        XCTAssertTrue(reloads.contains(PendingShipmentSelection.kind))
        reloads.removeAll()
        try store.updateStatusThrowing(id: value.id, status: .delivered)
        XCTAssertTrue(reloads.contains(PendingShipmentSelection.kind))
        reloads.removeAll()
        let preview = try storage.previewBackup(storage.exportBackup())
        try store.confirmBackupImport(preview, policy: .keepExisting)
        XCTAssertTrue(reloads.contains(PendingShipmentSelection.kind))
    }
    func testDeleteClearsPhoneAndAssociatedRecord() throws {
        let value = try add("SF1234567890123")
        try store.shipmentPhones.save("0123", for: value)
        try store.deleteThrowing(id: value.id)
        XCTAssertNil(try store.shipmentPhones.read(for: value))
        XCTAssertTrue(try storage.snapshot().shipments.isEmpty)
        XCTAssertTrue(try storage.snapshot().records.isEmpty)
    }
    func testDeleteRejectsQueryLeaseAndKeychainFailure() throws {
        let value = try add("SF1234567890123")
        try store.shipmentPhones.save("0123", for: value)
        let lease = try storage.acquireTrackingQuery(id: value.id)
        XCTAssertThrowsError(try store.deleteThrowing(id: value.id))
        lease.release()
        keys.fail = true
        XCTAssertThrowsError(try store.deleteThrowing(id: value.id))
        keys.fail = false
        XCTAssertEqual(try store.shipmentPhones.read(for: value), "0123")
        XCTAssertEqual(try storage.snapshot().shipments.count, 1)
    }
    func testBatchDeleteClearsOnlySelectedTickets() throws {
        let a = try add("SF1234567890123"), b = try add("SF2234567890123")
        try store.shipmentPhones.save("0123", for: a)
        try store.shipmentPhones.save("4567", for: b)
        store.delete(at: IndexSet(integer: 0), in: [a, b])
        XCTAssertNil(try store.shipmentPhones.read(for: a))
        XCTAssertEqual(try store.shipmentPhones.read(for: b), "4567")
        XCTAssertEqual(try storage.snapshot().shipments.map(\.id), [b.id])
    }
    func testCompletedSelectionStaysAutomaticWhenReopened() throws {
        let a = try add("SF1234567890123"), b = try add("SF2234567890123")
        try storage.transaction { $0.pendingShipmentBrowsingID = b.id }
        try store.updateStatusThrowing(id: b.id, status: .delivered)
        XCTAssertNil(try storage.snapshot().pendingShipmentBrowsingID)
        try store.updateStatusThrowing(id: b.id, status: .inTransit)
        XCTAssertEqual(PendingShipmentSelection.selected(in: try storage.snapshot())?.id, a.id)
    }
    func testAnySharedWriteClearsInvalidSelectionButPreservesValidSelection() throws {
        let a = try add("SF1234567890123"), b = try add("SF2234567890123")
        try storage.transaction { $0.pendingShipmentBrowsingID = b.id }
        XCTAssertEqual(try storage.snapshot().pendingShipmentBrowsingID, b.id)
        try storage.transaction { data in
            let index = try XCTUnwrap(data.shipments.firstIndex { $0.id == b.id })
            data.shipments[index].status = .archived
        }
        XCTAssertNil(try storage.snapshot().pendingShipmentBrowsingID)
        try storage.transaction { data in
            let index = try XCTUnwrap(data.shipments.firstIndex { $0.id == b.id })
            data.shipments[index].status = .inTransit
        }
        XCTAssertEqual(PendingShipmentSelection.selected(in: try storage.snapshot())?.id, a.id)
    }
    func testStalePersistedSelectionReportsAutomaticWithoutReadSideWrite() throws {
        _ = try add("SF1234567890123")
        var data = try storage.snapshot()
        data.pendingShipmentBrowsingID = UUID()
        XCTAssertFalse(PendingShipmentSelection.isBrowsing(in: data))
    }
}
