import XCTest
import UserNotifications
@testable import ParcelKeeper

@MainActor
final class StorageNotificationReviewTests: XCTestCase {
    private var root: URL!
    private var storage: SharedPickupStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try SharedPickupStore(appGroupID: nil, containerURL: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func seed() throws -> Shipment {
        let item = Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf")
        try storage.transaction { data in
            data.shipments.append(item)
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: "", source: "", shipmentID: item.id))
        }
        return item
    }
    private func replacement(_ old: Shipment) throws -> BackupPreview {
        var data = try storage.snapshot()
        data.shipments[0].id = UUID()
        data.records[0].id = UUID()
        data.records[0].shipmentID = data.shipments[0].id
        return try storage.previewBackup(JSONEncoder().encode(data))
    }
    func testReplacementCleansOnlyRetiredPhoneAfterCommitAndPreservesNewCredential() throws {
        let old = try seed(), keys = TrackingRefreshTests.PhoneKeys()
        let phones = ShipmentPhoneStore(keys: keys)
        try phones.save("0123", for: old)
        let preview = try replacement(old)
        let incoming = preview.incoming.shipments[0]
        try phones.save("5678", for: incoming)
        _ = try storage.importBackup(preview, policy: .replaceExisting)
        // Simulate process death after dataset commit but before Keychain cleanup.
        let restarted = try SharedPickupStore(appGroupID: nil, containerURL: root)
        try restarted.cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertNil(try phones.read(for: old))
        XCTAssertEqual(try phones.read(for: incoming), "5678")
        try restarted.cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertEqual(try phones.read(for: incoming), "5678")
        XCTAssertFalse(String(decoding: try restarted.exportBackup(), as: UTF8.self).contains("5678"))
    }
    func testReplacementRejectsActiveQueryBeforeCommit() throws {
        let old = try seed(), preview = try replacement(old)
        let lease = try storage.acquireTrackingQuery(id: old.id)
        defer { lease.release() }
        XCTAssertThrowsError(try storage.importBackup(preview, policy: .replaceExisting))
        XCTAssertEqual(try storage.snapshot().shipments, [old])
    }

    func testHistoricalCleanupRejectsBeforeKeychainSideEffects() throws {
        _ = try seed()
        let historical = try SharedPickupStore(appGroupID: nil, containerURL: root, readOnly: true)
        var calls = 0
        XCTAssertThrowsError(try historical.cleanupRetiredShipmentPhones { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
    }
    func testSameIdentityReplacementPreservesCredential() throws {
        let old = try seed(), keys = TrackingRefreshTests.PhoneKeys()
        let phones = ShipmentPhoneStore(keys: keys)
        try phones.save("0123", for: old)
        var incoming = try storage.snapshot()
        incoming.shipments[0].carrierName = "更新名称"
        let preview = try storage.previewBackup(JSONEncoder().encode(incoming))
        _ = try storage.importBackup(preview, policy: .replaceExisting)
        try storage.cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertEqual(try phones.read(for: old), "0123")
    }
    func testKeepExistingDoesNotClearValidPhone() throws {
        let old = try seed(), keys = TrackingRefreshTests.PhoneKeys()
        let phones = ShipmentPhoneStore(keys: keys)
        try phones.save("0123", for: old)
        _ = try storage.importBackup(replacement(old), policy: .keepExisting)
        try storage.cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertEqual(try phones.read(for: old), "0123")
    }
    func testKeychainCleanupFailureIsRetriedAfterRestart() throws {
        let old = try seed(), keys = TrackingRefreshTests.PhoneKeys()
        let phones = ShipmentPhoneStore(keys: keys)
        try phones.save("0123", for: old)
        _ = try storage.importBackup(replacement(old), policy: .replaceExisting)
        keys.fail = true
        XCTAssertThrowsError(try storage.cleanupRetiredShipmentPhones(clear: phones.clear))
        keys.fail = false
        try SharedPickupStore(appGroupID: nil, containerURL: root).cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertNil(try phones.read(for: old))
    }
    func testResetRejectsMissingAndStaleBindingWithoutChangingFixedChoice() throws {
        let old = TrainWidgetBinding(slot: .a, mode: .automatic, browsingTicketID: UUID())
        let current = TrainWidgetBinding(slot: .a, mode: .fixed, ticketID: UUID())
        try storage.transaction { $0.trainWidgetBindings = [current] }
        XCTAssertThrowsError(try storage.resetTrainWidgetBrowsing(slot: .a))
        XCTAssertThrowsError(try storage.resetTrainWidgetBrowsing(slot: .a, expectedBinding: old))
        XCTAssertEqual(try storage.snapshot().trainWidgetBindings, [current])
        try storage.resetTrainWidgetBrowsing(slot: .a, expectedBinding: current)
        XCTAssertEqual(try storage.snapshot().trainWidgetBindings?.first, TrainWidgetBinding(slot: .a, mode: .automatic))
    }
    func testAbsoluteReminderComponentsSurviveDeviceTimezoneAndDSTChange() throws {
        for text in ["2027-03-14T09:30:00Z", "2027-11-07T09:30:00Z"] {
            let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: text))
            let components = NotificationManager.absoluteReminderComponents(for: instant)
            XCTAssertEqual(components.timeZone, TimeZone(secondsFromGMT: 0))
            var calendar = Calendar(identifier: .gregorian)
            for zone in ["Asia/Shanghai", "America/Los_Angeles", "Europe/London"] {
                calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                XCTAssertEqual(calendar.date(from: components), instant)
            }
        }
    }
    func testReconciliationUsesWritableAuthoritativeSnapshotAndRetriesChangedData() async throws {
        _ = try seed()
        let store = ShipmentStore(storageProvider: { self.storage })
        var calls = 0
        store.reminderReconciler = { shipments in
            calls += 1
            if calls == 1 { try! self.storage.transaction { $0.shipments[0].reminderDate = Date().addingTimeInterval(600) } }
            else { XCTAssertNotNil(shipments[0].reminderDate) }
            return []
        }
        let errors = await store.reconcileReminders()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(calls, 2)
        let historical = try SharedPickupStore(appGroupID: nil, containerURL: root, readOnly: true)
        let historyStore = ShipmentStore(storageProvider: { historical })
        historyStore.reminderReconciler = { _ in XCTFail("Historical data must not operate notifications"); return [] }
        _ = await historyStore.reconcileReminders()
    }
    func testStartupReconciliationRepairsInterruptedSystemWriteAndIsRepeatable() async throws {
        let old = try seed()
        let future = Date().addingTimeInterval(600)
        try storage.transaction { $0.shipments[0].reminderDate = future }
        // Model a killed process: the durable desired date exists but no system request.
        var pending: [UUID: Date] = [:]
        for _ in 0..<2 {
            let restarted = ShipmentStore(storageProvider: {
                try SharedPickupStore(appGroupID: nil, containerURL: self.root)
            })
            restarted.reminderReconciler = { shipments in
                pending = Dictionary(uniqueKeysWithValues: shipments.compactMap { item in
                    item.reminderDate.map { (item.id, $0) }
                })
                return []
            }
            let errors = await restarted.reconcileReminders()
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(pending, [old.id: future])
        }
    }
}
