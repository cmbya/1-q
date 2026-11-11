import XCTest
@testable import ParcelKeeper

final class KDYZMPickupRepairTests: XCTestCase {
    private let collected = "快件已按约定投递，取件人凭取件码完成取件，感谢使用极兔速递，期待再次为您服务。"
    private func snapshot(text: String = "较新轨迹", status: String = "arrived") -> KDYZMSnapshot {
        KDYZMSnapshot(schemaVersion: 1, serverRevision: 1, accounts: [],
            orders: [.init(id: "o", accountId: "a", platform: "jd", platformOrderId: "po", familyId: "f")],
            shipments: [.init(id: "s", orderId: "o", accountId: "a", familyId: "f", waybillNo: "JD123456789012", carrier: "京东物流", status: status,
                logisticsEvents: [.init(time: 300_000, timeText: "", description: text, location: "")], logisticsState: "ok", logisticsCheckedAt: 400_000, logisticsUpdatedAt: 400_000)],
            hiddenIds: [], deletedIds: [], familyIds: ["f"], legacyAccountIds: [], families: [])
    }
    private func dataset(source: String? = nil, channel: String? = nil) -> PickupDataset {
        let group = PickupGroup(name: "快递", sortOrder: 0)
        var local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd", note: "私人备注", pickupCode: "42", logisticsInfo: "旧付费节点", logisticsTime: Date(timeIntervalSince1970: 200), queryInfo: "原历史", refreshChannel: channel)
        local.logisticsSource = source
        return PickupDataset(groups: [group], records: [PickupRecord(groupID: group.id, code: "42", location: "私有地点", source: "私人备注", shipmentID: local.id)], shipments: [local], expressGroupID: group.id)
    }
    func testHistoricalPaidSourceDoesNotOverrideFollowBackend() throws {
        for source in ["uapi", "tmini"] {
            var data = dataset(source: source)
            let record = data.records[0]
            let report = try KDYZMMerger.apply(snapshot(text: collected, status: "transit"), origin: "https://example.com", to: &data)
            XCTAssertEqual(report.updated, 1)
            XCTAssertEqual(data.shipments[0].logisticsSource, "kdyzm")
            XCTAssertEqual(data.shipments[0].status, .delivered)
            XCTAssertNil(data.shipments[0].refreshChannel)
            XCTAssertEqual(data.shipments[0].note, "私人备注")
            XCTAssertTrue(data.shipments[0].queryInfo?.contains("原历史") == true)
            var expected = record
            expected.isCompleted = true
            expected.updatedAt = data.records[0].updatedAt
            XCTAssertEqual(data.records[0], expected)
        }
    }
    func testExplicitPaidOverridesPreserveTraceAndStatus() throws {
        for channel in ["uapi", "tmini"] {
            var data = dataset(source: channel, channel: channel)
            _ = try KDYZMMerger.apply(snapshot(text: collected), origin: "https://example.com", to: &data)
            XCTAssertEqual(data.shipments[0].logisticsInfo, "旧付费节点")
            XCTAssertEqual(data.shipments[0].logisticsSource, channel)
            XCTAssertNotEqual(data.shipments[0].status, .delivered)
            XCTAssertFalse(data.records[0].isCompleted)
        }
    }
    func testIdenticalSnapshotIsUnchangedIncludingTimestamps() throws {
        var data = dataset()
        let remote = snapshot(text: collected)
        _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        let before = data.shipments[0]
        let report = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.unchanged, 1)
        XCTAssertEqual(data.shipments[0], before)
    }
    func testActualCollectionOverridesCoarseTransitOrArrived() throws {
        for status in ["transit", "arrived"] {
            var local = dataset().shipments[0]
            XCTAssertTrue(try KDYZMMerger.update(snapshot(text: collected, status: status).shipments[0], local: &local))
            XCTAssertEqual(local.status, .delivered)
        }
    }
    func testCollectionHelperRejectsStationRequestsNegationAndConditional() {
        XCTAssertTrue(MallDeliveryState.recipientCollected(latest: collected))
        for text in ["驿站已签收，请凭码取件", "请凭取件码完成取件", "请收件人凭取件码完成取件", "取件人尚未凭取件码完成取件", "取件人凭取件码完成取件后请评价", "预计收件人已取件", "快递员已取件", "包裹已签收"] {
            XCTAssertFalse(MallDeliveryState.recipientCollected(latest: text), text)
        }
    }
    func testOnlyNewestEventsMayProveCollection() throws {
        var remote = snapshot(text: "驿站已签收，请凭码取件").shipments[0]
        remote.logisticsEvents?.append(.init(time: 100_000, timeText: "", description: collected, location: ""))
        var local = dataset().shipments[0]
        XCTAssertTrue(try KDYZMMerger.update(remote, local: &local))
        XCTAssertEqual(local.status, .readyForPickup)
    }
    func testSameTimestampCollectionAndOrdinaryConflictsUseThisResponse() throws {
        var local = dataset(source: "uapi").shipments[0]
        local.logisticsTime = Date(timeIntervalSince1970: 300)
        XCTAssertTrue(try KDYZMMerger.update(snapshot(text: collected).shipments[0], local: &local))
        XCTAssertEqual(local.status, .delivered)
        XCTAssertEqual(local.logisticsInfo, collected)
        XCTAssertTrue(local.queryInfo?.contains(collected) == true)
        XCTAssertTrue(local.queryInfo?.contains("原历史") == true)
        XCTAssertEqual(local.logisticsSource, "kdyzm")
        local.status = .inTransit
        XCTAssertTrue(try KDYZMMerger.update(snapshot(text: "冲突节点").shipments[0], local: &local))
        XCTAssertEqual(local.logisticsInfo, "冲突节点")
        XCTAssertEqual(local.status, .readyForPickup)
    }
    func testOlderSnapshotReplacesMainNodeAndCacheTimestampButRetainsHistory() throws {
        var data = dataset()
        let remote = snapshot(text: "本次较早节点", status: "transit")
        data.shipments[0].status = .readyForPickup
        data.shipments[0].logisticsTime = Date(timeIntervalSince1970: 900)
        data.shipments[0].backendLogisticsUpdatedAt = Date(timeIntervalSince1970: 1000)
        data.shipments[0].backendEvents = [.init(time: 900_000, timeText: "", description: "已有较晚历史", location: "")]
        let record = data.records[0]
        let report = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(data.shipments[0].logisticsInfo, "本次较早节点")
        XCTAssertEqual(data.shipments[0].logisticsTime, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(data.shipments[0].backendLogisticsUpdatedAt, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(data.shipments[0].status, .inTransit)
        XCTAssertTrue(data.shipments[0].queryInfo?.contains("已有较晚历史") == true)
        XCTAssertEqual(data.records[0], record)
    }
    func testEmptySnapshotDoesNotPromoteExistingTicketOrClearHistory() throws {
        var data = dataset()
        var remote = snapshot(text: collected, status: "signed")
        remote.shipments[0].logisticsEvents = []
        remote.shipments[0].logisticsState = "empty"
        _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertNotEqual(data.shipments[0].status, .delivered)
        XCTAssertEqual(data.shipments[0].logisticsInfo, "旧付费节点")
        XCTAssertFalse(data.records[0].isCompleted)
    }
    func testRefreshCompletesPickupButBoolStillMeansNewShipmentDelivery() async throws {
        for (initial, override) in [(ShipmentStatus.inTransit, Optional<Bool>.none), (.delivered, nil), (.inTransit, false)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
            let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
            var local = dataset().shipments[0]
            local.status = initial; local.originPlatform = "jd"; local.platformOrderID = "po"
            local.backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
            try store.transaction { data in
                data.shipments.append(local)
                data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", source: "私人备注", shipmentID: local.id, completionOverride: override))
            }
            let payload: [String: Any] = ["schemaVersion": 1, "serverRevision": 1, "accounts": [], "familyIds": ["f"], "hiddenIds": [], "deletedIds": [],
                "orders": [["id": "o", "accountId": "a", "platform": "jd", "platformOrderId": "po", "familyId": "f"]],
                "shipments": [["id": "s", "orderId": "o", "accountId": "a", "familyId": "f", "waybillNo": local.trackingNumber, "carrier": "京东物流", "status": "transit", "pickupCompletion": ["version": 1, "autoPicked": true, "manualOverride": ""], "logisticsState": "ok", "logisticsCheckedAt": 400_000, "logisticsUpdatedAt": 400_000, "logisticsEvents": [["time": 300_000, "timeText": "", "description": "平台确认已领取", "location": ""]]]]]
            let transport = KDYZMNetworkTests.Transport()
            transport.responses = [(Data(#"{"accepted":true,"jobs":[{"id":"j","accountId":"a","orderId":"o","state":"completed","logisticsState":"ok","createdAt":900000}]}"#.utf8), 202), (try JSONSerialization.data(withJSONObject: payload), 200)]
            let keys = KDYZMNetworkTests.Keys(); keys.value = credential
            let client = KDYZMClient(transport: transport)
            let service = KDYZMRefreshService(store: store, connection: KDYZMConnection(keys: keys, client: client), client: client, reloadWidgets: {})
            let newlyDelivered = try await service.refresh(before: local)
            XCTAssertEqual(newlyDelivered, initial != .delivered)
            XCTAssertEqual(try store.snapshot().shipments.first?.status, .delivered)
            XCTAssertEqual(try XCTUnwrap(store.snapshot().records.first).isCompleted, override != false)
            XCTAssertNil(try store.snapshot().shipments.first?.backendRefreshJobID)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }
    func testBackendCompletionPrecedenceMatchesAndroid() {
        var remote = snapshot(text: collected).shipments[0]
        remote.picked = true
        for (automatic, manual, expected) in [(true, "", true), (false, "picked", true), (true, "pending", false), (false, "", false)] {
            remote.pickupCompletion = .init(version: 1, autoPicked: automatic, manualOverride: manual)
            XCTAssertEqual(KDYZMMerger.recipientCollected(remote), expected, manual)
        }
        remote.pickupCompletion = nil
        remote.logisticsEvents = []; remote.logisticsState = "empty"
        XCTAssertTrue(KDYZMMerger.recipientCollected(remote)) // legacy effective picked
        remote.picked = false
        XCTAssertFalse(KDYZMMerger.recipientCollected(remote))
    }
    func testCompletedHistoryImportsAndRepairsPreviouslyPendingRecordsWithoutCache() throws {
        for platform in ["taobao", "pdd"] {
            var remote = snapshot()
            remote.orders[0].platform = platform
            remote.shipments[0].pickupCompletion = .init(version: 1, autoPicked: true, manualOverride: "")
            remote.shipments[0].logisticsState = "empty"
            remote.shipments[0].logisticsEvents = []
            var data = dataset()
            _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
            XCTAssertEqual(data.shipments[0].status, .delivered)
            XCTAssertTrue(data.records[0].isCompleted)
            XCTAssertEqual(data.shipments[0].logisticsInfo, "旧付费节点")
            XCTAssertNil(data.shipments[0].lastQueriedAt)
            // Simulate a pre-fix record: the shipment already says delivered.
            data.records[0].isCompleted = false
            XCTAssertEqual(try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data).updated, 1)
            XCTAssertTrue(data.records[0].isCompleted)
            let saved = data
            XCTAssertEqual(try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data).unchanged, 1)
            XCTAssertEqual(data, saved)
            data.shipments = []; data.records = []
            _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
            XCTAssertEqual(data.shipments[0].status, .delivered)
            XCTAssertTrue(data.records[0].isCompleted)
        }
    }
    func testTaobaoCodeReceiptLegacySnapshotCompletesExistingAndNewPickup() throws {
        let text = "已签收，签收人凭取货码签收。感谢使用DGCY圆通及新港西路214号宿舍大院值班室旁丰巢柜【自提柜】，期待再次为您服务。"
        var remote = snapshot(text: text)
        remote.orders[0].platform = "taobao"
        for existing in [true, false] {
            var data = dataset()
            if !existing { data.shipments = []; data.records = [] }
            _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
            XCTAssertEqual(data.shipments[0].status, .delivered)
            XCTAssertTrue(data.records[0].isCompleted)
        }
    }
    func testStationDepositAndGenericSignedNeverCompletePickup() throws {
        for text in ["驿站已签收，请凭取件码取件", "包裹已存入丰巢快递柜，等待取件", "包裹已签收"] {
            var data = dataset()
            _ = try KDYZMMerger.apply(snapshot(text: text), origin: "https://example.com", to: &data)
            XCTAssertFalse(data.records[0].isCompleted, text)
            XCTAssertEqual(data.shipments[0].status, .readyForPickup, text)
        }
    }
    func testServerPendingWinsOverLegacyPickedAndCompletionText() throws {
        var remote = snapshot(text: collected)
        remote.shipments[0].picked = true
        remote.shipments[0].pickupCompletion = .init(version: 1, autoPicked: true, manualOverride: "pending")
        var data = dataset()
        _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertFalse(data.records[0].isCompleted)
        XCTAssertEqual(data.shipments[0].status, .readyForPickup)
        data.records[0].isCompleted = true
        let completed = data.records[0]
        _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertEqual(data.records[0], completed) // server cannot reopen local completion
    }
    func testCompletedHistoryCanReusePendingCodeWithoutBlockingSnapshot() throws {
        var remote = snapshot()
        remote.shipments[0].pickupCode = "42"
        remote.shipments[0].picked = true
        var data = dataset()
        data.shipments = []; data.records = [PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42")]
        _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &data)
        XCTAssertEqual(data.records.filter { !$0.isCompleted }.count, 1)
        XCTAssertEqual(data.records.filter { $0.isCompleted }.count, 1)
    }
    @MainActor func testManualReopenPersistsAcrossSnapshotAndBackupRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let remote = snapshot(text: collected)
        try storage.transaction { _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &$0) }
        let app = ShipmentStore(storageProvider: { storage })
        let id = try XCTUnwrap(app.pickupRecords.first?.id)
        try app.setPickupCompleted(id: id, completed: false)
        let before = try storage.snapshot().records[0]
        XCTAssertEqual(before.completionOverride, false)
        try storage.transaction { _ = try KDYZMMerger.apply(remote, origin: "https://example.com", to: &$0) }
        XCTAssertEqual(try storage.snapshot().records[0], before)
        let decoded = try JSONDecoder().decode(PickupDataset.self, from: JSONEncoder().encode(storage.snapshot()))
        XCTAssertEqual(decoded.records[0].completionOverride, false)
        try app.setPickupCompleted(id: id, completed: true)
        XCTAssertEqual(try storage.snapshot().records[0].completionOverride, true)
    }
    func testCodeReceiptRejectsCorrectionsInstructionsAndForecasts() {
        for code in ["取货", "取件"] {
            XCTAssertTrue(MallDeliveryState.recipientCollected(latest: "已签收，签收人凭\(code)码签收。丰巢柜【自提柜】"))
            for text in ["请签收人凭\(code)码签收", "签收人凭\(code)码签收后请评价", "签收人凭\(code)码签收，实际未收到包裹", "预计签收人凭\(code)码签收", "签收人凭\(code)码签收？", "签收人凭\(code)码签收失败", "如您已签收，签收人凭\(code)码签收请忽略"] {
                XCTAssertFalse(MallDeliveryState.recipientCollected(latest: text), text)
            }
        }
        XCTAssertTrue(MallDeliveryState.recipientCollected(latest: "本人已签收"))
        XCTAssertFalse(MallDeliveryState.recipientCollected(latest: "非本人已签收"))
    }
    func testInvalidCompletionSchemaRejectsSnapshot() throws {
        for completion in [KDYZMPickupCompletion(version: 2, autoPicked: true, manualOverride: ""), .init(version: 1, autoPicked: true, manualOverride: "unknown")] {
            var remote = snapshot()
            remote.shipments[0].pickupCompletion = completion
            XCTAssertThrowsError(try remote.validated())
        }
        let record = PickupRecord(groupID: UUID(), code: "42")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "completionOverride")
        XCTAssertNil(try JSONDecoder().decode(PickupRecord.self, from: JSONSerialization.data(withJSONObject: json)).completionOverride)
    }
    func testCompletionDecodesFromActualSnapshotShipmentShape() throws {
        let json = #"{"id":"s","orderId":"o","accountId":"a","waybillNo":"YT7653693173234","carrier":"圆通","status":"arrived","picked":true,"pickupCompletion":{"version":1,"autoPicked":true,"manualOverride":"","completedAt":300000,"evidence":{"kind":"user_collected"}}}"#
        let remote = try JSONDecoder().decode(KDYZMRemoteShipment.self, from: Data(json.utf8))
        XCTAssertTrue(try XCTUnwrap(remote.pickupCompletion).autoPicked)
        XCTAssertTrue(KDYZMMerger.recipientCollected(remote))
    }
}
