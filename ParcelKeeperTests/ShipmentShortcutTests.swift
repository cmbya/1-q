import XCTest
@testable import ParcelKeeper

final class ShipmentShortcutTests: XCTestCase {
    private var directory: URL!
    private var store: SharedPickupStore!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("missing"), containerURL: directory)
        _ = try store.snapshot()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func input(_ info: String? = nil, state: ShipmentStatus? = nil, time: Date? = nil) -> ShipmentShortcutInput {
        .init(trackingNumber: "YT1234567890123", carrierName: nil, logisticsInfo: info, status: state, logisticsTime: time)
    }
    func testUpsertPreservesIdentityNotesRemindersAndCompletesOnlyLinkedCode() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        XCTAssertTrue(try service.upsert(input("运输中")))
        let original = try XCTUnwrap(store.snapshot().shipments.first)
        let reminder = Date(timeIntervalSinceReferenceDate: 2000)
        try store.transaction { data in
            data.shipments[0].note = "保留备注"
            data.shipments[0].pickupCode = "3-4-1366"
            data.shipments[0].reminderDate = reminder
            data.records[0].source = "保留备注"
            data.records[0].code = "3-4-1366"
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: "OTHER"))
        }
        XCTAssertFalse(try service.upsert(input("本人签收")))
        let after = try store.snapshot()
        XCTAssertEqual(after.shipments.count, 1)
        XCTAssertEqual(after.shipments[0].id, original.id)
        XCTAssertEqual(after.shipments[0].createdAt, original.createdAt)
        XCTAssertEqual(after.shipments[0].status, .delivered)
        XCTAssertEqual(after.shipments[0].pickupCode, "3-4-1366")
        XCTAssertEqual(after.shipments[0].note, "保留备注")
        XCTAssertEqual(after.shipments[0].reminderDate, reminder)
        XCTAssertTrue(try XCTUnwrap(after.records.first { $0.shipmentID == original.id }).isCompleted)
        XCTAssertFalse(try XCTUnwrap(after.records.first { $0.code == "OTHER" }).isCompleted)
        XCTAssertFalse(try service.upsert(input()))
        XCTAssertEqual(try store.snapshot().shipments[0].logisticsInfo, "本人签收")
    }
    func testOldOrCompletedRegressionWritesNothing() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        XCTAssertTrue(try service.upsert(input("已签收", time: Date(timeIntervalSinceReferenceDate: 2000))))
        let before = try store.exportBackup()
        XCTAssertThrowsError(try service.upsert(input("运输中", time: Date(timeIntervalSinceReferenceDate: 1000))))
        XCTAssertEqual(try store.exportBackup(), before)
        XCTAssertThrowsError(try service.upsert(input("运输中")))
        XCTAssertEqual(try store.exportBackup(), before)
    }
    func testStatusNegationAndPickupAreNotCompletion() {
        for text in ["未签收", "待签收", "尚未签收", "等待领取", "已放入快递柜，待取件"] {
            XCTAssertEqual(ShipmentShortcutParser.status(text), .readyForPickup, text)
        }
        XCTAssertNil(ShipmentShortcutParser.status("未取件"))
        XCTAssertEqual(ShipmentShortcutParser.status("已领取"), .delivered)
        XCTAssertEqual(ShipmentShortcutParser.status("正在派送"), .outForDelivery)
    }
    func testLatestEventChosenIndependentOfInputOrder() throws {
        let text = "圆通速递 运单号：YT1234567890123\n2026-10-29 09:00 已到达转运中心\n2026-10-30 11:00 本人签收"
        let parsed = try ShipmentShortcutParser.parse(text)
        XCTAssertEqual(parsed.status, .delivered)
        XCTAssertEqual(parsed.logisticsInfo, "本人签收")
        XCTAssertEqual(parsed.logisticsTime, ShipmentShortcutParser.date("2026-10-30 11:00"))
        let reversed = text.components(separatedBy: .newlines).reversed().joined(separator: "\n")
        XCTAssertEqual(try ShipmentShortcutParser.parse(reversed), parsed)
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("运单号：YT1234567890123\n已签收\n运输中"))
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("运单号：YT1234567890123\n运单号：SF1234567890123\n已签收"))
    }
    func testMinisJSONAndInvalidNumber() throws {
        let json = #"{"trackingNumber":"YT1234567890123","carrierName":"圆通速递","logisticsInfo":"已签收","logisticsTime":"2026-10-30T11:00:00+08:00"}"#
        let parsed = try ShipmentShortcutParser.parse(json)
        XCTAssertEqual(parsed.carrierName, "圆通速递")
        XCTAssertEqual(parsed.status, .delivered)
        XCTAssertNotNil(parsed.logisticsTime)
        XCTAssertThrowsError(try ShipmentShortcutParser.number("13800138000"))
        XCTAssertThrowsError(try ShipmentShortcutParser.number("YT1234567890123 http://bad"))
    }
    func testOldShipmentJSONRemainsDecodableAndNewFieldsRoundTripBackup() throws {
        let shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(shipment)) as? [String: Any])
        object.removeValue(forKey: "logisticsInfo"); object.removeValue(forKey: "logisticsTime")
        let decoded = try JSONDecoder().decode(Shipment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.logisticsInfo)
        XCTAssertNil(decoded.logisticsTime)
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        _ = try service.upsert(input("派送中", time: Date(timeIntervalSinceReferenceDate: 1234.5)))
        let bytes = try store.exportBackup()
        let decodedBackup = try JSONDecoder().decode(PickupDataset.self, from: bytes)
        XCTAssertEqual(decodedBackup.shipments[0].logisticsInfo, "派送中")
        XCTAssertEqual(decodedBackup.shipments[0].logisticsTime, Date(timeIntervalSinceReferenceDate: 1234.5))
    }
    func testFourConfirmationSwitchesDefaultOnAndCanBeDisabled() {
        var a = AddPickupIntent(); var b = RecognizePickupIntent()
        var c = AddShipmentIntent(); var d = RecognizeShipmentIntent()
        XCTAssertTrue(a.confirmBeforeSaving); XCTAssertTrue(b.confirmBeforeSaving)
        XCTAssertTrue(c.confirmBeforeSaving); XCTAssertTrue(d.confirmBeforeSaving)
        a.confirmBeforeSaving = false; b.confirmBeforeSaving = false
        c.confirmBeforeSaving = false; d.confirmBeforeSaving = false
        XCTAssertFalse(a.confirmBeforeSaving); XCTAssertFalse(b.confirmBeforeSaving)
        XCTAssertFalse(c.confirmBeforeSaving); XCTAssertFalse(d.confirmBeforeSaving)
    }
}
