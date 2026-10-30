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
    func testQueryTimestampDoesNotOverrideLatestLogisticsInEitherOrder() throws {
        let expectedTime = ShipmentShortcutParser.date("2026-10-30 11:00")
        for metadata in ["查询时间：2026-10-30 12:00", "2026-10-30 12:00 查詢時間"] {
            let lines = [metadata, "2026-10-30 11:00 本人签收"]
            for history in [lines, Array(lines.reversed())] {
                let text = "运单号：YT1234567890123\n" + history.joined(separator: "\n")
                let parsed = try ShipmentShortcutParser.parse(text)
                XCTAssertEqual(parsed.logisticsInfo, "本人签收")
                XCTAssertEqual(parsed.logisticsTime, expectedTime)
                XCTAssertEqual(parsed.status, .delivered)
            }
        }
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        let history = "查询时间：2026-10-30 12:00\n2026-10-30 11:00 本人签收"
        _ = try service.upsert(ShipmentShortcutParser.parse("运单号：YT1234567890123\n" + history))
        let saved = try store.snapshot()
        XCTAssertEqual(saved.shipments[0].logisticsTime, expectedTime)
        XCTAssertEqual(saved.shipments[0].status, .delivered)
        XCTAssertTrue(saved.records[0].isCompleted)
        // A later real event is not older than the saved query timestamp.
        XCTAssertFalse(try service.upsert(input("已领取", time: ShipmentShortcutParser.date("2026-10-30 11:30"))))
        let json = try JSONSerialization.data(withJSONObject: ["trackingNumber": "YT1234567890123", "logisticsInfo": history])
        let parsedJSON = try ShipmentShortcutParser.parse(try XCTUnwrap(String(data: json, encoding: .utf8)))
        XCTAssertEqual(parsedJSON.logisticsInfo, "本人签收")
        XCTAssertEqual(parsedJSON.logisticsTime, expectedTime)
        let direct = try service.validate(input(history))
        XCTAssertEqual(direct.logisticsInfo, "本人签收")
        XCTAssertEqual(direct.logisticsTime, expectedTime)
    }
    func testQueryTimestampAloneNeverBecomesLogistics() throws {
        let parsed = try ShipmentShortcutParser.parse("运单号：YT1234567890123\n查询时间：2026-10-30 12:00")
        XCTAssertNil(parsed.logisticsInfo)
        XCTAssertNil(parsed.logisticsTime)
        XCTAssertNil(parsed.status)
        let undated = try ShipmentShortcutParser.parse("运单号：YT1234567890123\n查询时间：2026-10-30 12:00\n本人签收")
        XCTAssertEqual(undated.logisticsInfo, "本人签收")
        XCTAssertEqual(undated.status, .delivered)
        XCTAssertNil(undated.logisticsTime)
    }
    func testRealEventMentioningQueryTimeIsNotDiscarded() throws {
        let parsed = try ShipmentShortcutParser.parse("运单号：YT1234567890123\n2026-10-30 11:00 本人签收（查询时间见页面）")
        XCTAssertEqual(parsed.logisticsInfo, "本人签收（查询时间见页面）")
        XCTAssertEqual(parsed.status, .delivered)
        XCTAssertEqual(parsed.logisticsTime, ShipmentShortcutParser.date("2026-10-30 11:00"))
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
    func testStationReceiptDoesNotCompleteLinkedRecordOrAcceptExplicitCompletion() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        _ = try service.upsert(input("已签收，菜鸟驿站代收"))
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.shipments[0].status, .readyForPickup)
        XCTAssertFalse(snapshot.records[0].isCompleted)
        let before = try store.exportBackup()
        XCTAssertThrowsError(try service.upsert(input("已签收，丰巢代收", state: .delivered)))
        XCTAssertEqual(try store.exportBackup(), before)
        XCTAssertEqual(ShipmentShortcutParser.status("本人签收，取件地点丰巢"), .delivered)
    }
    func testEventPrefixAndLatestReturnSurviveTextJSONAndDirectValidation() throws {
        let history = "2026-10-29 09:00 已签收\n退回寄件人 2026-10-30 11:00"
        let parsed = try ShipmentShortcutParser.parse("运单号：YT1234567890123\n" + history)
        XCTAssertEqual(parsed.logisticsInfo, "退回寄件人")
        XCTAssertEqual(parsed.status, .exception)
        XCTAssertEqual(parsed.logisticsTime, ShipmentShortcutParser.date("2026-10-30 11:00"))
        let json = try JSONSerialization.data(withJSONObject: ["trackingNumber": "YT1234567890123", "logisticsInfo": history])
        let structured = try ShipmentShortcutParser.parse(try XCTUnwrap(String(data: json, encoding: .utf8)))
        XCTAssertEqual(structured.status, parsed.status)
        XCTAssertEqual(structured.logisticsInfo, parsed.logisticsInfo)
        XCTAssertEqual(structured.logisticsTime, parsed.logisticsTime)
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        let direct = try service.validate(input(history))
        XCTAssertEqual(direct.status, .exception)
        XCTAssertEqual(direct.logisticsInfo, "退回寄件人")
        XCTAssertThrowsError(try service.validate(input(history, time: ShipmentShortcutParser.date("2026-10-29 09:00"))))
    }
    func testFractionalISOEventTimestampIsNotSplitIntoDescription() throws {
        let stamp = "2026-10-30T11:00:00.125+08:00"
        let parsed = try ShipmentShortcutParser.parse("运单号：YT1234567890123\n\(stamp) 本人签收")
        XCTAssertEqual(parsed.logisticsInfo, "本人签收")
        XCTAssertEqual(parsed.logisticsTime, ShipmentShortcutParser.date(stamp))
        XCTAssertEqual(parsed.status, .delivered)
    }
    func testAmbiguousHistoriesAndExtraUnlabeledParcelAreRejected() throws {
        for text in [
            "运单号：YT1234567890123\n2026-10-30 11:00 已签收\n2026-10-30 11:00 退回",
            "运单号：YT1234567890123\n已签收\n退回",
            "运单号：YT1234567890123 SF1234567890123 已签收"
        ] { XCTAssertThrowsError(try ShipmentShortcutParser.parse(text), text) }
        XCTAssertEqual(ShipmentShortcutParser.numbers(in: "运单号：YT1234567890123 待取件，取件码12345678"), ["YT1234567890123"])
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
    func testNegatedRecipientReceiptAndExplicitCompletionCannotBypassCustody() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        for info in ["非本人签收", "未经收件人签收", "未取件，已签收驿站代收"] {
            XCTAssertNotEqual(ShipmentShortcutParser.status(info), .delivered, info)
            XCTAssertThrowsError(try service.validate(input(info, state: .delivered)), info)
            let json = try JSONSerialization.data(withJSONObject: ["trackingNumber": "YT1234567890123", "logisticsInfo": info, "status": "已签收"])
            XCTAssertThrowsError(try ShipmentShortcutParser.parse(try XCTUnwrap(String(data: json, encoding: .utf8))), info)
        }
        // A denial without a positive state still cannot authorize completion.
        XCTAssertThrowsError(try service.validate(input("未取件", state: .delivered)))
    }
    func testCandidateDiscoveryDoesNotDependOnCarrierConfidenceOrFieldSubstrings() throws {
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("运单号 YT1234567890123 AB123456 已签收"))
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("运单号 YT1234567890123 87654321 已签收"))
        for noise in ["订单号12345678", "order:12345678", "code:12345678", "取件码：12345678", "手机号13800138000", "日期20261030"] {
            XCTAssertEqual(ShipmentShortcutParser.numbers(in: "运单号 YT1234567890123 " + noise), ["YT1234567890123"], noise)
        }
        for bad in ["ordertrackingNumber:AB123456", "订单号:AB123456", "_AB123456", "AB123456_", "X-AB123456", "AB123456-XYZ", String(repeating: "A", count: 30) + "12345678"] {
            XCTAssertTrue(ShipmentShortcutParser.numbers(in: bad).isEmpty, bad)
        }
        XCTAssertEqual(try ShipmentShortcutParser.parse("运单号：12345678 已签收").trackingNumber, "12345678")
        XCTAssertEqual(try ShipmentShortcutParser.parse(#"{"trackingNumber":"12345678","logisticsInfo":"待取件，code:87654321"}"#).trackingNumber, "12345678")
    }
    func testStationTitleIsNotAnUndatedEvent() throws {
        let parsed = try ShipmentShortcutParser.parse("菜鸟驿站 运单号：YT1234567890123\n2026-10-30 11:00 本人签收")
        XCTAssertEqual(parsed.status, .delivered)
        XCTAssertEqual(parsed.logisticsInfo, "本人签收")
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("运单号：YT1234567890123\n待取件\n2026-10-30 11:00 本人签收"))
    }
    func testRepeatedReceiptPreservesManualReopeningUntilLogisticsActuallyChanges() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        _ = try service.upsert(input("运输中"))
        _ = try service.upsert(input("本人签收"))
        XCTAssertTrue(try store.snapshot().records[0].isCompleted)
        try store.transaction { $0.records[0].isCompleted = false }
        _ = try service.upsert(input("本人签收"))
        XCTAssertFalse(try store.snapshot().records[0].isCompleted)
        _ = try service.upsert(input("已领取"))
        XCTAssertFalse(try store.snapshot().records[0].isCompleted)
    }
    func testStatusChangeRejectsDuplicateReopeningAtomicallyAndCanRetry() throws {
        var reloads = 0
        let service = ShipmentShortcutService(store: store, reloadWidgets: { reloads += 1 })
        _ = try service.upsert(input("运输中"))
        let original = try XCTUnwrap(store.snapshot().shipments.first)
        let linkedID = try XCTUnwrap(store.snapshot().records.first?.id)
        let competingID = UUID()
        try store.transaction { data in
            data.shipments[0].pickupCode = " 42 "
            data.records[0].code = " 42 "
            data.records[0].isCompleted = true
            data.records.append(PickupRecord(id: competingID, groupID: data.records[0].groupID, code: "42"))
        }
        let before = try store.exportBackup()
        let dataURL = directory.appendingPathComponent("ParcelKeeper/pickup-data.json")
        let beforeFile = try Data(contentsOf: dataURL)
        var update = input("待取件")
        update.carrierName = "新服务商"
        XCTAssertThrowsError(try service.upsert(update)) { error in
            guard case PickupStorageError.invalidData = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try store.exportBackup(), before)
        XCTAssertEqual(try Data(contentsOf: dataURL), beforeFile)
        XCTAssertEqual(reloads, 1, "A rejected write must not reload widgets")
        try store.transaction { data in
            let index = try XCTUnwrap(data.records.firstIndex { $0.id == competingID })
            data.records[index].isCompleted = true
        }
        XCTAssertFalse(try service.upsert(update))
        let after = try store.snapshot()
        XCTAssertEqual(after.shipments[0].id, original.id)
        XCTAssertEqual(after.shipments[0].status, .readyForPickup)
        XCTAssertEqual(after.shipments[0].carrierName, "新服务商")
        XCTAssertFalse(try XCTUnwrap(after.records.first { $0.id == linkedID }).isCompleted)
        XCTAssertTrue(try XCTUnwrap(after.records.first { $0.id == competingID }).isCompleted)
        XCTAssertEqual(reloads, 2)
    }
    func testShortcutStatusChangePreservesExistingPendingHistoryDuplicates() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        _ = try service.upsert(input("运输中"))
        try store.transaction { data in
            data.shipments[0].pickupCode = "42"
            data.records[0].code = "42"
            data.records.append(PickupRecord(groupID: data.records[0].groupID, code: "42"))
            data.records.append(PickupRecord(groupID: data.groups[1].id, code: "42"))
        }
        XCTAssertFalse(try service.upsert(input("待取件")))
        XCTAssertEqual(try store.snapshot().records.filter { !$0.isCompleted }.count, 3)
        XCTAssertFalse(try service.upsert(input("本人签收")))
        let after = try store.snapshot()
        XCTAssertTrue(after.records[0].isCompleted)
        XCTAssertFalse(after.records[1].isCompleted)
        XCTAssertFalse(after.records[2].isCompleted)
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
