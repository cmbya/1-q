import XCTest
@testable import ParcelKeeper

final class TrackingRefreshTests: XCTestCase {
    final class Client: UAPITrackingQuerying {
        var onQuery: (() throws -> Void)?
        var failure: Error?
        var calls = 0
        var queriedNumbers: [String] = []
        var result = UAPITrackingResult(trackingNumber: "YT1234567890123", carrierName: "圆通速递", carrierCode: "yuantong", status: .delivered, logisticsInfo: "本人签收", logisticsTime: Date(timeIntervalSinceReferenceDate: 2000), queryInfo: "完整查询信息", queriedAt: Date(timeIntervalSinceReferenceDate: 3000))
        func query(trackingNumber: String, carrierCode: String?, phone: String?, refresh: Bool) async throws -> UAPITrackingResult {
            calls += 1
            queriedNumbers.append(trackingNumber)
            try onQuery?()
            if let failure { throw failure }
            return result
        }
    }
    var root: URL!
    var storage: SharedPickupStore!
    var shipment: Shipment!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", note: "保留", pickupCode: "42", reminderDate: Date(timeIntervalSinceReferenceDate: 5000))
        try storage.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: shipment.pickupCode, source: shipment.note, shipmentID: shipment.id))
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testRefreshPreservesIdentityAndUpdatesBothViewsWithoutTextInference() async throws {
        let client = Client()
        let service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        let newlyDelivered = try await service.refresh(id: shipment.id)
        XCTAssertTrue(newlyDelivered)
        let after = try storage.snapshot()
        XCTAssertEqual(after.shipments[0].id, shipment.id)
        XCTAssertEqual(after.shipments[0].note, "保留")
        XCTAssertEqual(after.shipments[0].pickupCode, "42")
        XCTAssertEqual(after.shipments[0].reminderDate, shipment.reminderDate)
        XCTAssertEqual(after.shipments[0].uapiCarrierCode, "yuantong")
        XCTAssertEqual(after.shipments[0].lastQueriedAt, client.result.queriedAt)
        XCTAssertNil(after.shipments[0].lastCheckedAt)
        XCTAssertEqual(after.shipments[0].queryInfo, "完整查询信息")
        XCTAssertTrue(after.records[0].isCompleted)
    }
    func testDeletedRecordIsNotRecreatedAfterNetworkReturns() async throws {
        let client = Client()
        client.onQuery = { try self.storage.transaction { $0.shipments.removeAll(); $0.records.removeAll() } }
        do { _ = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refresh(id: shipment.id); XCTFail() }
        catch { XCTAssertTrue(try storage.snapshot().shipments.isEmpty) }
    }
    func testNetworkFailureAndOlderResultPreserveData() async throws {
        let client = Client()
        let service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        let before = try storage.exportBackup()
        client.failure = UAPIError.unavailable
        do { _ = try await service.refresh(id: shipment.id); XCTFail() } catch {}
        XCTAssertEqual(try storage.exportBackup(), before)
        client.failure = nil
        try storage.transaction { $0.shipments[0].logisticsTime = Date(timeIntervalSinceReferenceDate: 4000) }
        let newer = try storage.exportBackup()
        do { _ = try await service.refresh(id: shipment.id); XCTFail() } catch {}
        XCTAssertEqual(try storage.exportBackup(), newer)
    }
    func testUnknownStatusPreservesStateAndCompletedRecordsAreNotBatched() async throws {
        let client = Client()
        client.result = UAPITrackingResult(trackingNumber: shipment.trackingNumber, carrierName: "", carrierCode: "", status: nil, logisticsInfo: "状态未知", logisticsTime: nil, queryInfo: "状态未知", queriedAt: Date())
        let service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        _ = try await service.refresh(id: shipment.id)
        XCTAssertEqual(try storage.snapshot().shipments[0].status, .inTransit)
        try storage.transaction { $0.shipments[0].status = .delivered; $0.records[0].isCompleted = true }
        let report = try await service.refreshPending()
        XCTAssertEqual(report.succeeded, 0)
        XCTAssertEqual(client.calls, 1)
    }
    func testReopeningDuplicateAndMismatchedNumberNeverPartiallyWrite() async throws {
        let client = Client()
        client.result = UAPITrackingResult(trackingNumber: shipment.trackingNumber, carrierName: "新名称", carrierCode: "yuantong", status: .readyForPickup, logisticsInfo: "待取件", logisticsTime: nil, queryInfo: "新全文", queriedAt: Date())
        try storage.transaction { data in
            data.records[0].isCompleted = true
            data.records.append(PickupRecord(groupID: data.records[0].groupID, code: "42"))
        }
        let before = try storage.exportBackup()
        do { _ = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refresh(id: shipment.id); XCTFail() } catch {}
        XCTAssertEqual(try storage.exportBackup(), before)
        client.result = UAPITrackingResult(trackingNumber: "SF1234567890123", carrierName: "错误", carrierCode: "shunfeng", status: .delivered, logisticsInfo: "已签收", logisticsTime: nil, queryInfo: "错误全文", queriedAt: Date())
        do { _ = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refresh(id: shipment.id); XCTFail() } catch {}
        XCTAssertEqual(try storage.exportBackup(), before)
    }
    func testOldModelAndNewFieldsBackupCompatibility() throws {
        let encoded = try JSONEncoder().encode(shipment!)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lastQueriedAt"); object.removeValue(forKey: "uapiCarrierCode")
        object.removeValue(forKey: "lastQueryAttemptAt")
        let legacy = try JSONDecoder().decode(Shipment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.lastQueriedAt); XCTAssertNil(legacy.uapiCarrierCode)
        XCTAssertNil(legacy.lastQueryAttemptAt)
        try storage.transaction {
            $0.shipments[0].lastQueriedAt = Date(timeIntervalSinceReferenceDate: 1234)
            $0.shipments[0].lastQueryAttemptAt = Date(timeIntervalSinceReferenceDate: 2345)
            $0.shipments[0].uapiCarrierCode = "yuantong"
        }
        let backup = try JSONDecoder().decode(PickupDataset.self, from: storage.exportBackup())
        XCTAssertEqual(backup.shipments[0].uapiCarrierCode, "yuantong")
        XCTAssertEqual(backup.shipments[0].lastQueriedAt, Date(timeIntervalSinceReferenceDate: 1234))
        XCTAssertEqual(backup.shipments[0].lastQueryAttemptAt, Date(timeIntervalSinceReferenceDate: 2345))
    }
    private func addPendingShipments(_ count: Int) throws {
        try storage.transaction { data in
            for index in 0..<count {
                var other = self.shipment!
                other.id = UUID()
                other.trackingNumber = "YT22345678901\(index)"
                data.shipments.append(other)
                data.records.append(PickupRecord(groupID: data.groups[0].id, code: "extra-\(index)", shipmentID: other.id))
            }
        }
    }
    func testTemporaryFailureContinuesBatchAndReportsSafePerParcelDetails() async throws {
        try addPendingShipments(1)
        let client = Client(); client.failure = UAPIError.unavailable
        let report = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refreshPending()
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(report.failed, 2)
        XCTAssertEqual(report.remaining, 0)
        XCTAssertNil(report.stoppedReason)
        XCTAssertTrue(report.message.contains(shipment.trackingNumber))
        XCTAssertTrue(report.message.contains(UAPIError.unavailable.localizedDescription))
        XCTAssertEqual(report.failures.count, report.failed)
    }
    func testSlowFailedAttemptsRotateAcrossServiceInstancesWithoutChangingLogistics() async throws {
        try addPendingShipments(2)
        let before = try storage.snapshot().shipments
        let client = Client(); client.failure = UAPIError.noData
        var uptime: TimeInterval = 0
        client.onQuery = { uptime += 12 }
        let first = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}, uptime: { uptime }).refreshPending()
        XCTAssertEqual(first.failed, 2)
        XCTAssertEqual(first.remaining, 1)
        _ = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}, uptime: { uptime }).refreshPending()
        XCTAssertEqual(Set(client.queriedNumbers.prefix(3)).count, 3)
        for old in before {
            var after = try XCTUnwrap(storage.snapshot().shipments.first { $0.id == old.id })
            XCTAssertNotNil(after.lastQueryAttemptAt)
            after.lastQueryAttemptAt = old.lastQueryAttemptAt
            XCTAssertEqual(after, old)
        }
    }
    func testUnknownBatchErrorNeverEchoesRawSecrets() async throws {
        let client = Client()
        client.failure = NSError(domain: "Bearer secret phone=9876", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer secret phone=9876"])
        let report = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refreshPending()
        XCTAssertTrue(report.message.contains(shipment.trackingNumber))
        XCTAssertFalse(report.message.contains("secret"))
        XCTAssertFalse(report.message.contains("9876"))
    }
    func testPostSaveWarningsRetainQueryAndEachReminderFailure() {
        for reminder in ["没有通知权限", "提醒保存失败", "提醒创建失败"] {
            let message = ShipmentPostSaveWarnings.message(query: "物流查询未完成", reminder: reminder)
            XCTAssertTrue(message.contains("物流查询未完成"))
            XCTAssertTrue(message.contains(reminder))
            XCTAssertTrue(message.contains("快递已保存"))
        }
        XCTAssertEqual(ShipmentPostSaveWarnings.message(query: nil, reminder: "提醒创建失败"), "快递已保存。\n提醒创建失败")
    }
    func testBatchStopsOnAuthenticationAndExcludesCompleted() async throws {
        let client = Client(); client.failure = UAPIError.authentication
        try storage.transaction { data in
            var other = self.shipment!; other.id = UUID(); other.trackingNumber = "SF1234567890123"
            data.shipments.append(other)
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: other.pickupCode, source: other.note, shipmentID: other.id))
        }
        let report = try await TrackingRefreshService(store: storage, client: client, reloadWidgets: {}).refreshPending()
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.remaining, 1)
    }
}
