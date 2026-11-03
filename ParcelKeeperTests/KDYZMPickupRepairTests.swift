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
            XCTAssertEqual(data.records[0], record)
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
    func testSameTimestampCollectionRepairsStatusWithoutOverwritingConflictingTrace() throws {
        var local = dataset(source: "uapi").shipments[0]
        local.logisticsTime = Date(timeIntervalSince1970: 300)
        let oldInfo = local.logisticsInfo, oldHistory = local.queryInfo
        XCTAssertTrue(try KDYZMMerger.update(snapshot(text: collected).shipments[0], local: &local))
        XCTAssertEqual(local.status, .delivered)
        XCTAssertEqual(local.logisticsInfo, oldInfo)
        XCTAssertEqual(local.queryInfo, oldHistory)
        XCTAssertEqual(local.logisticsSource, "uapi")
        local.status = .inTransit
        let before = local
        XCTAssertFalse(try KDYZMMerger.update(snapshot(text: "冲突节点").shipments[0], local: &local))
        XCTAssertEqual(local, before)
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
    func testRefreshBoolIsNewShipmentDeliveryNotManualRecordCompletion() async throws {
        for initial in [ShipmentStatus.inTransit, .delivered] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
            let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
            var local = dataset().shipments[0]
            local.status = initial; local.originPlatform = "jd"; local.platformOrderID = "po"
            local.backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
            try store.transaction { data in
                data.shipments.append(local)
                data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", source: "私人备注", shipmentID: local.id))
            }
            let payload: [String: Any] = ["schemaVersion": 1, "serverRevision": 1, "accounts": [], "familyIds": ["f"], "hiddenIds": [], "deletedIds": [],
                "orders": [["id": "o", "accountId": "a", "platform": "jd", "platformOrderId": "po", "familyId": "f"]],
                "shipments": [["id": "s", "orderId": "o", "accountId": "a", "familyId": "f", "waybillNo": local.trackingNumber, "carrier": "京东物流", "status": "transit", "logisticsState": "ok", "logisticsCheckedAt": 400_000, "logisticsUpdatedAt": 400_000, "logisticsEvents": [["time": 300_000, "timeText": "", "description": collected, "location": ""]]]]]
            let transport = KDYZMNetworkTests.Transport()
            transport.responses = [(Data(#"{"accepted":true,"jobs":[{"id":"j","accountId":"a","orderId":"o","state":"completed","logisticsState":"ok","createdAt":200000}]}"#.utf8), 202), (try JSONSerialization.data(withJSONObject: payload), 200)]
            let keys = KDYZMNetworkTests.Keys(); keys.value = credential
            let client = KDYZMClient(transport: transport)
            let service = KDYZMRefreshService(store: store, connection: KDYZMConnection(keys: keys, client: client), client: client, reloadWidgets: {})
            let newlyDelivered = try await service.refresh(before: local)
            XCTAssertEqual(newlyDelivered, initial != .delivered)
            XCTAssertEqual(try store.snapshot().shipments.first?.status, .delivered)
            XCTAssertFalse(try XCTUnwrap(store.snapshot().records.first).isCompleted)
            XCTAssertNil(try store.snapshot().shipments.first?.backendRefreshJobID)
            XCTAssertEqual(transport.requests.count, 2)
        }
    }
}
