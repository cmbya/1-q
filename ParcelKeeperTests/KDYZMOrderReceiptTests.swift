import XCTest
@testable import ParcelKeeper

final class KDYZMOrderReceiptTests: XCTestCase {
    private let origin = "https://example.com"
    private func data() -> PickupDataset {
        let group = PickupGroup(name: "快递", sortOrder: 0)
        return PickupDataset(groups: [group], records: [], shipments: [], expressGroupID: group.id)
    }
    private func snapshot(text: String? = nil, status: String = "signed") -> KDYZMSnapshot {
        var ships: [KDYZMRemoteShipment] = []
        if let text {
            ships = [.init(id: "s", orderId: "o", accountId: "a", familyId: "f",
                waybillNo: "JD123456789012", carrier: "京东物流", status: status,
                logisticsEvents: [.init(time: 300_000, timeText: "", description: text, location: "")],
                logisticsState: "ok", logisticsCheckedAt: 400_000, logisticsUpdatedAt: 400_000)]
        }
        return KDYZMSnapshot(schemaVersion: 1, serverRevision: 1, accounts: [],
            orders: [.init(id: "o", accountId: "a", platform: "jd", platformOrderId: "po", familyId: "f", title: "商品", tradeStatus: "WAIT_SELLER_SEND_GOODS")],
            shipments: ships, hiddenIds: [], deletedIds: [], familyIds: ["f"], legacyAccountIds: [], families: [])
    }
    func testPendingOrderPersistsWithoutFabricatingShipmentOrPickup() throws {
        var local = data()
        let report = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local)
        XCTAssertEqual(report.noWaybill, 1)
        XCTAssertEqual(local.backendPendingOrders?.count, 1)
        XCTAssertEqual(local.backendPendingOrders?.first?.statusText, "待发货 · 暂无运单号")
        XCTAssertTrue(local.shipments.isEmpty)
        XCTAssertTrue(local.records.isEmpty)
        let before = local
        _ = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local)
        XCTAssertEqual(local, before)
        XCTAssertEqual(try JSONDecoder().decode(PickupDataset.self, from: JSONEncoder().encode(local)), local)
    }
    func testWaybillReplacesPendingCardAndSplitParcelsRemainSeparate() throws {
        var local = data()
        _ = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local)
        var remote = snapshot(text: "运输中", status: "transit")
        var split = remote.shipments[0]
        split.id = "s2"; split.waybillNo = "JD123456789013"
        remote.shipments.append(split)
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        XCTAssertEqual(local.backendPendingOrders?.count, 0)
        XCTAssertEqual(local.shipments.count, 2)
        XCTAssertEqual(local.records.count, 2)
    }
    func testEndedHiddenDeletedArchivedAndLocalDeliveryAreExcluded() throws {
        for status in ["TRADE_FINISHED", "TRADE_CLOSED", "WAIT_BUYER_PAY", "已签收", "退款成功"] {
            var remote = snapshot(); remote.orders[0].tradeStatus = status
            var local = data()
            _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
            XCTAssertTrue((local.backendPendingOrders ?? []).isEmpty, status)
        }
        for variant in 0..<5 {
            var remote = snapshot()
            switch variant {
            case 0: remote.orders[0].hidden = true
            case 1: remote.orders[0].deleted = true
            case 2: remote.orders[0].archived = true
            case 3: remote.orders[0].fulfillmentType = "local_delivery"
            default: remote.deletedIds = ["o"]
            }
            var local = data()
            _ = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local)
            _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
            XCTAssertTrue((local.backendPendingOrders ?? []).isEmpty)
        }
    }
    func testPartialSnapshotPreservesPendingOrderAndAccountIdentity() throws {
        var local = data()
        _ = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local)
        var remote = snapshot(); remote.orders[0].id = "o2"; remote.orders[0].accountId = "a2"
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        XCTAssertEqual(local.backendPendingOrders?.count, 2)
        remote.orders = []
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        XCTAssertEqual(local.backendPendingOrders?.count, 2)
    }
    func testNoWaybillOrdersReceiveFieldAndScopeValidation() throws {
        var remote = snapshot(); remote.orders[0].title = String(repeating: "a", count: 501)
        XCTAssertThrowsError(try remote.validated())
        remote = snapshot(); remote.orders[0].title = "bad\nname"
        XCTAssertThrowsError(try remote.validated())
        remote = snapshot(); remote.familyIds = []
        XCTAssertThrowsError(try remote.validated())
    }
    func testHomeDeliveryRequiresConfirmationAndHidesHistoricalCode() throws {
        var local = data()
        var remote = snapshot(text: "包裹已送到家门口")
        remote.shipments[0].pickupCode = "12-34"
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        let shipment = try XCTUnwrap(local.shipments.first)
        XCTAssertTrue(shipment.needsReceiptConfirmation)
        XCTAssertEqual(shipment.statusDisplayText, "已送达 · 待确认收到")
        XCTAssertFalse(local.records[0].isCompleted)
        XCTAssertFalse(local.pickupCodeActive(local.records[0]))
        XCTAssertEqual(PendingShipmentSelection.eligible(local.shipments).map(\.id), [shipment.id])
        let before = local
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        XCTAssertEqual(local, before)
    }
    func testHomeDeliveryRejectsStationForecastFailureAndRequests() {
        for text in ["已送到家门口", "包裹已经放在门前", "包裹已妥投"] {
            XCTAssertTrue(MallDeliveryState.homeDelivered(events: [text], status: "signed", station: "", hasPickupCode: false), text)
        }
        for text in ["已送到菜鸟驿站门口", "包裹已放入丰巢柜", "门卫已签收", "预计已送到家门口", "尚未送达", "包裹送达失败", "请放在家门口", "预约送货上门", "已签收，实际未送达", "已拒收退回"] {
            XCTAssertFalse(MallDeliveryState.homeDelivered(events: [text], status: "signed", station: "", hasPickupCode: false), text)
        }
        XCTAssertFalse(MallDeliveryState.homeDelivered(events: ["已签收"], status: "signed", station: "丰巢", hasPickupCode: false))
        XCTAssertFalse(MallDeliveryState.homeDelivered(events: ["已签收"], status: "signed", station: "", hasPickupCode: true))
    }
    @MainActor
    func testConfirmUndoAndResyncPreserveExplicitChoice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let remote = snapshot(text: "包裹已送到家门口")
        try storage.transaction { local in _ = try KDYZMMerger.apply(remote, origin: origin, to: &local) }
        let store = ShipmentStore(storageProvider: { storage })
        let id = try XCTUnwrap(store.shipments.first?.id)
        for confirmed in [true, false] {
            try store.setReceiptConfirmed(id: id, confirmed: confirmed)
            try storage.transaction { local in _ = try KDYZMMerger.apply(remote, origin: origin, to: &local) }
            try store.reload()
            XCTAssertEqual(store.shipments[0].needsReceiptConfirmation, !confirmed)
            XCTAssertEqual(store.pickupRecords[0].isCompleted, confirmed)
            XCTAssertEqual(store.shipments[0].receiptConfirmedAt != nil, confirmed)
        }
    }
    func testLegacyCompletionAndOldSnapshotsStillWork() throws {
        var local = data()
        var remote = snapshot(text: "签收人凭取货码签收")
        remote.shipments[0].picked = true
        _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
        XCTAssertFalse(local.shipments[0].needsReceiptConfirmation)
        XCTAssertTrue(local.records[0].isCompleted)
        var old = data(); old.backendPendingOrders = nil
        let decoded = try JSONDecoder().decode(PickupDataset.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.backendPendingOrders)
    }
    func testPendingOrdersParticipateInBackupConflictPolicy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        try storage.transaction { local in _ = try KDYZMMerger.apply(snapshot(), origin: origin, to: &local) }
        var incoming = try storage.snapshot()
        incoming.backendPendingOrders?[0].title = "新商品"
        let bytes = try JSONEncoder().encode(incoming)
        let preview = try storage.previewBackup(bytes)
        XCTAssertTrue(preview.hasConflicts)
        XCTAssertThrowsError(try storage.importBackup(preview, policy: nil))
        _ = try storage.importBackup(preview, policy: .keepExisting)
        XCTAssertEqual(try storage.snapshot().backendPendingOrders?.first?.title, "商品")
        let replace = try storage.previewBackup(bytes)
        _ = try storage.importBackup(replace, policy: .replaceExisting)
        XCTAssertEqual(try storage.snapshot().backendPendingOrders?.first?.title, "新商品")
    }
    func testFailedOrUndatedTraceCannotInventHomeDelivery() throws {
        for kind in ["error", "empty", "undated"] {
            var remote = snapshot(text: "包裹已送到家门口")
            if kind == "undated" { remote.shipments[0].logisticsEvents?[0].time = 0 }
            else { remote.shipments[0].logisticsState = kind }
            var local = data()
            _ = try KDYZMMerger.apply(remote, origin: origin, to: &local)
            XCTAssertFalse(local.shipments[0].needsReceiptConfirmation, kind)
        }
    }
    func testOlderCacheDoesNotErasePendingReceipt() throws {
        var local = data()
        _ = try KDYZMMerger.apply(snapshot(text: "包裹已送到家门口"), origin: origin, to: &local)
        var old = snapshot(text: "运输中", status: "transit")
        old.shipments[0].logisticsEvents?[0].time = 100_000
        _ = try KDYZMMerger.apply(old, origin: origin, to: &local)
        XCTAssertTrue(local.shipments[0].needsReceiptConfirmation)
    }
    func testManualPickupCompletionIsRespectedWhenHomeDeliveryIsDiscovered() throws {
        var local = data()
        _ = try KDYZMMerger.apply(snapshot(text: "运输中", status: "transit"), origin: origin, to: &local)
        local.records[0].completionOverride = true
        local.records[0].isCompleted = true
        _ = try KDYZMMerger.apply(snapshot(text: "包裹已送到家门口"), origin: origin, to: &local)
        XCTAssertFalse(local.shipments[0].needsReceiptConfirmation)
        XCTAssertEqual(local.shipments[0].receiptConfirmed, true)
    }
}
