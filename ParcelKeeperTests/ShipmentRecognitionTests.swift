import XCTest
@testable import ParcelKeeper

final class ShipmentRecognitionTests: XCTestCase {
    private let progress = "快件已按约定投递，取件人凭取件码完成取件，感谢使用极兔速递，期待再次为您服务。"
    private var raw: String { "📦 快递单号：JT5539273200253 🚚 快递公司：极兔速递 📍 当前状态：已签收 🕒 最新时间：  📍 最新进展：\(progress) 🔍 查询来源：百度搜索（数据由快递100提供）" }

    func testLocalLabeledResultKeepsOnlyProgressWithNoInventedTime() throws {
        for text in [raw, raw.replacingOccurrences(of: " 🚚", with: "\n🚚").replacingOccurrences(of: " 📍", with: "\n📍")] {
            let value = try ShipmentShortcutParser.parse(text)
            XCTAssertEqual(value.trackingNumber, "JT5539273200253")
            XCTAssertEqual(value.carrierName, "极兔速递")
            XCTAssertEqual(value.logisticsInfo, progress)
            XCTAssertEqual(value.status, .delivered)
            XCTAssertNil(value.logisticsTime)
        }
        XCTAssertEqual(ShipmentShortcutParser.status("请凭取件码取件"), .readyForPickup)
    }
    func testLabeledMetadataWithoutProgressIsNotSavedAsLogistics() throws {
        let value = try ShipmentShortcutParser.parse("快递单号：JT5539273200253 当前状态：运输中 最新时间： 查询来源：百度搜索")
        XCTAssertNil(value.logisticsInfo)
        XCTAssertNil(value.logisticsTime)
        XCTAssertEqual(value.status, .inTransit)
        XCTAssertThrowsError(try ShipmentShortcutParser.parse("快递单号：JT5539273200253 最新进展：派送中 最新进展：已签收"))
    }
    func testCompletionRequestIsNotCompletedWithoutExplicitStatus() throws {
        for text in ["请凭取件码完成取件", "请尽快完成取件", "尚未完成取件"] {
            XCTAssertNotEqual(ShipmentShortcutParser.status(text), .delivered, text)
        }
        for text in ["取件人凭取件码完成取件", "已完成取件"] {
            XCTAssertEqual(ShipmentShortcutParser.status(text), .delivered, text)
        }
    }
    func testLabeledCurrentStatusHasPriorityThroughPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("missing"), containerURL: directory)
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        for (state, progress, expected) in [("已签收", "请凭取件码完成取件", ShipmentStatus.delivered),
                                            ("待取件", "已完成取件", .readyForPickup),
                                            ("已签收", "", .delivered)] {
            let text = "快递单号：JT5539273200253 当前状态：\(state) 最新进展：\(progress)"
            let parsed = try ShipmentShortcutParser.parse(text)
            XCTAssertEqual(parsed.status, expected)
            XCTAssertEqual(try service.validate(parsed).status, expected)
            // Isolate each case: completed shipments cannot auto-reopen.
            try store.transaction { data in data.records.removeAll(); data.shipments.removeAll() }
            XCTAssertTrue(try service.upsert(parsed))
            XCTAssertEqual(try store.snapshot().shipments[0].status, expected)
            XCTAssertEqual(try store.snapshot().records[0].isCompleted, expected == .delivered)
        }
        let withoutState = try ShipmentShortcutParser.parse("快递单号：JT5539273200253 最新进展：请凭取件码完成取件")
        XCTAssertEqual(withoutState.status, .readyForPickup)
    }
    func testAIPathDoesNotRequireLocalRecognitionOrOverrideAIState() async throws {
        let expected = ShipmentShortcutInput(trackingNumber: "JT5539273200253", carrierName: "极兔速递", logisticsInfo: "驿站已签收", status: .delivered, logisticsTime: nil)
        let result = try await ShipmentRecognition.recognize("unrecognized local text", useAI: true) { text in
            XCTAssertEqual(text, "unrecognized local text")
            return expected
        }
        var expectedWithOriginal = expected
        expectedWithOriginal.queryInfo = "unrecognized local text"
        XCTAssertEqual(result.input, expectedWithOriginal)
        XCTAssertTrue(result.usesAI)
    }
    func testAIFailureNeverFallsBackToLocallyParsableText() async throws {
        do {
            _ = try await ShipmentRecognition.recognize(raw, useAI: true) { _ in throw AIServiceError.unavailable }
            XCTFail("Must report AI failure, not return local data")
        } catch { XCTAssertEqual(error as? AIServiceError, .unavailable) }
        let local = try await ShipmentRecognition.recognize(raw, useAI: false) { _ in
            XCTFail("Disabled AI must not be called")
            throw AIServiceError.disabled
        }
        XCTAssertFalse(local.usesAI)
        XCTAssertEqual(local.input.logisticsInfo, progress)
    }
    func testFullQueryIsStoredVerbatimOnBothRecognitionPaths() async throws {
        for useAI in [false, true] {
            let result = try await ShipmentRecognition.recognize(raw, useAI: useAI) { _ in
                ShipmentShortcutInput(trackingNumber: "JT5539273200253", carrierName: "极兔速递", logisticsInfo: self.progress, status: .delivered, logisticsTime: nil, queryInfo: "AI must not rewrite the original")
            }
            XCTAssertEqual(result.input.queryInfo, raw)
            XCTAssertEqual(result.input.logisticsInfo, progress)
        }
    }
    func testFullQueryUpdatesIndependentlyOfStatusAndSurvivesBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("missing"), containerURL: directory)
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        var value = ShipmentShortcutInput(trackingNumber: "JT5539273200253", carrierName: nil, logisticsInfo: "派送中", status: .outForDelivery, logisticsTime: nil, queryInfo: "  原文：历史已签收\n本次派送中  ")
        XCTAssertTrue(try service.upsert(value))
        let original = try store.snapshot().shipments[0]
        XCTAssertEqual(original.queryInfo, value.queryInfo)
        XCTAssertEqual(original.status, .outForDelivery)
        XCTAssertFalse(try store.snapshot().records[0].isCompleted)
        value.queryInfo = "新查询全文：已签收（历史记录），当前派送中"
        XCTAssertFalse(try service.upsert(value))
        value.queryInfo = nil
        XCTAssertFalse(try service.upsert(value))
        XCTAssertEqual(try store.snapshot().shipments[0].queryInfo, "新查询全文：已签收（历史记录），当前派送中")
        XCTAssertEqual(try store.snapshot().shipments[0].id, original.id)
        XCTAssertEqual(try store.snapshot().shipments[0].status, .outForDelivery)
        let backup = try store.exportBackup()
        let restored = try JSONDecoder().decode(PickupDataset.self, from: backup)
        XCTAssertEqual(restored.shipments[0].queryInfo, "新查询全文：已签收（历史记录），当前派送中")
        XCTAssertEqual(restored.shipments[0].logisticsInfo, "派送中")
        value.queryInfo = String(repeating: "x", count: 10001)
        XCTAssertThrowsError(try service.upsert(value))
        XCTAssertEqual(try store.exportBackup(), backup)
    }
    func testOldShipmentWithoutQueryInfoStillDecodes() throws {
        let shipment = Shipment(trackingNumber: "JT5539273200253", carrierName: "极兔速递", carrierCode: "jt")
        let bytes = try JSONEncoder().encode(shipment)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "queryInfo")
        let decoded = try JSONDecoder().decode(Shipment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.queryInfo)
        XCTAssertEqual(decoded.id, shipment.id)
    }
    func testAIResultPassesPersistenceWithoutLocalSemanticReclassification() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("missing"), containerURL: directory)
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        let value = ShipmentShortcutInput(trackingNumber: "JT5539273200253", carrierName: "极兔速递", logisticsInfo: "驿站已签收", status: .delivered, logisticsTime: nil)
        XCTAssertThrowsError(try service.validate(value))
        XCTAssertEqual(try service.validate(value, inferLogistics: false), value)
        XCTAssertTrue(try service.upsert(value, inferLogistics: false))
        XCTAssertEqual(try store.snapshot().shipments[0].status, .delivered)
        XCTAssertTrue(try store.snapshot().records[0].isCompleted)
        var invalid = value
        invalid.trackingNumber = "bad"
        XCTAssertThrowsError(try service.upsert(invalid, inferLogistics: false))
    }
}
