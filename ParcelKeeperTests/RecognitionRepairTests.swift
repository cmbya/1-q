import XCTest
@testable import ParcelKeeper

// Added before implementation. Requires macOS/iOS XCTest; not compiled in the Linux no-build workflow.
final class RecognitionRepairTests: XCTestCase {
    private let journey = "出发日期：2026-11-04\n车次：G123\n出发站：北京南\n发车时间：09:00\n到达站：上海虹桥"

    func testGateDoesNotCountAsSecondTrainLocallyOrAtAIEntry() async throws {
        for gate in ["C2", "D12", "G1", "C2、C3"] {
            let raw = journey + "\n检票口：" + gate
            let local = try TrainTicketRecognition.parse(raw)
            XCTAssertEqual(local.trainNumber, "G123")
            XCTAssertEqual(local.gate, gate)
            var calls = 0
            let ai = try await TrainTicketRecognition.recognize(raw, useAI: true) { _ in calls += 1; return local }
            XCTAssertEqual(ai, local)
            XCTAssertEqual(calls, 1)
        }
        let withoutLabel = "2026-11-04\n检票口：C2\nG123\n北京南 09:00\n上海虹桥 14:00"
        XCTAssertEqual(try TrainTicketRecognition.parse(withoutLabel).trainNumber, "G123")
        for second in ["\nG124", "\n车次：G123", "\n检票口：C2\nD123"] {
            XCTAssertThrowsError(try TrainTicketRecognition.parse(journey + second))
        }
    }

    func testEnglishPassengerListsAreRejectedWithoutTruncatingToFirstName() async throws {
        XCTAssertEqual(try TrainTicketRecognition.parse(journey + "\n乘车人：John Smith").passenger, "John Smith")
        for passenger in ["John Smith; Jane Doe", "John Smith；Jane Doe", "John Smith, Jane Doe", "John Smith/Jane Doe", "张三 李四"] {
            let raw = journey + "\n乘车人：" + passenger
            XCTAssertTrue(TrainTicketRecognition.hasMultiplePassengers(passenger))
            XCTAssertThrowsError(try TrainTicketRecognition.parse(raw)) { error in
                guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") }
            }
            var calls = 0
            do {
                _ = try await TrainTicketRecognition.recognize(raw, useAI: true) { _ in calls += 1; return TrainTicketFields() }
                XCTFail("Ambiguous passenger list accepted")
            } catch { guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") } }
            XCTAssertEqual(calls, 0)
        }
    }

    func testElevenDigitTrackingAndPhonePolicyIsSharedWithoutRepairingTokens() throws {
        for number in ["10012345678", "11012345678", "12012345678"] {
            XCTAssertEqual(try ShipmentShortcutParser.number(number), number)
            XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "运单号：" + number), [number])
            XCTAssertEqual(ShipmentShortcutParser.numbers(in: number), [number])
            XCTAssertEqual(SmartShipmentParser.parseSingleNumber(number)?.trackingNumber, number)
        }
        for phone in ["13012345678", "13800138000", "19912345678"] {
            XCTAssertThrowsError(try ShipmentShortcutParser.number(phone))
            XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: "运单号：" + phone).isEmpty)
        }
        for bad in ["SF12345678-90123", "SF1234567890123#", "SF1234567890123_", "+SF1234567890123"] {
            XCTAssertThrowsError(try ShipmentShortcutParser.number(bad))
            XCTAssertNil(SmartShipmentParser.parseSingleNumber(bad))
            XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: bad).isEmpty, bad)
        }
        XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: "手机号：11012345678").isEmpty, "Explicit field ownership still excludes non-mobile phone fields")
    }

    func testDraftPreservesSelectedLatestEventTimeAndOriginalQuery() throws {
        let raw = "运单号：YT1234567890123\n2026-11-03 09:00 已揽收\n2026-11-04 10:00 正在发往驿站"
        let draft = try XCTUnwrap(SmartShipmentParser.parse(raw).first)
        XCTAssertEqual(draft.logisticsInfo, "正在发往驿站")
        XCTAssertEqual(draft.logisticsTime, ShipmentShortcutParser.date("2026-11-04 10:00"))
        XCTAssertEqual(draft.queryInfo, raw)
        XCTAssertEqual(draft.status, .inTransit)
        let plain = ShipmentImportDraft(trackingNumber: "AB123456", carrier: CarrierDetector.unknown, confidence: 0)
        XCTAssertNil(plain.logisticsInfo)
        XCTAssertNil(plain.logisticsTime)
        XCTAssertNil(plain.queryInfo)
        let json = #"{"trackingNumber":"AB123456","logisticsInfo":"运输中","queryInfo":"原始查询","logisticsTime":"2026-11-04 09:00"}"#
        let jsonDraft = try XCTUnwrap(SmartShipmentParser.parse(json).first)
        XCTAssertEqual(jsonDraft.queryInfo, "原始查询")
        XCTAssertEqual(jsonDraft.logisticsInfo, "运输中")
        XCTAssertEqual(jsonDraft.logisticsTime, ShipmentShortcutParser.date("2026-11-04 09:00"))
    }

    @MainActor
    func testDraftLogisticsPersistsThroughShipmentStoreAndJSONRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let app = ShipmentStore(storageProvider: { shared })
        let raw = "运单号：AB123456\n2026-11-04 09:00 运输中"
        let draft = try XCTUnwrap(SmartShipmentParser.parse(raw).first)
        let value = Shipment(trackingNumber: draft.trackingNumber, carrierName: draft.carrier.name, carrierCode: draft.carrier.code,
                             status: draft.status, note: draft.note, pickupCode: draft.pickupCode,
                             logisticsInfo: draft.logisticsInfo, logisticsTime: draft.logisticsTime, queryInfo: draft.queryInfo)
        try app.addThrowing(value)
        let saved = try XCTUnwrap(shared.snapshot().shipments.first)
        XCTAssertEqual(saved, value)
        XCTAssertEqual(saved.logisticsInfo, "运输中")
        XCTAssertEqual(saved.logisticsTime, ShipmentShortcutParser.date("2026-11-04 09:00"))
        XCTAssertEqual(saved.queryInfo, raw)
        XCTAssertEqual(try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(saved)), saved)
        let old = Shipment(trackingNumber: "AB123457", carrierName: "未知", carrierCode: "unknown")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["logisticsInfo", "logisticsTime", "queryInfo"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(Shipment.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.logisticsInfo)
        XCTAssertNil(legacy.logisticsTime)
        XCTAssertNil(legacy.queryInfo)
    }

    func testStatusUsesEventSemanticsInsteadOfDestinationName() throws {
        for text in ["包裹正在发往驿站", "运输中，目的地为快递柜", "已发出至丰巢"] {
            XCTAssertEqual(ShipmentShortcutParser.status(text), .inTransit, text)
        }
        XCTAssertEqual(ShipmentShortcutParser.status("快递员派送中，目的地为驿站"), .outForDelivery)
        for text in ["已到达菜鸟驿站", "已签收，快递柜代收", "驿站待取件", "请凭取件码完成取件", "若已完成取件请忽略", "取件码尚未使用，未完成取件"] {
            XCTAssertEqual(ShipmentShortcutParser.status(text), .readyForPickup, text)
        }
        XCTAssertEqual(ShipmentShortcutParser.status("收件人凭取件码完成取件"), .delivered)
        XCTAssertThrowsError(try ShipmentShortcutParser.latestEvent(in: "已签收\n包裹正在发往驿站"))
        let latest = try ShipmentShortcutParser.latestEvent(in: "2026-11-03 09:00 驿站代收\n2026-11-04 09:00 包裹正在发往驿站")
        XCTAssertEqual(latest.state, .inTransit)
        XCTAssertThrowsError(try ShipmentShortcutParser.parse(#"{"trackingNumber":"AB123456","status":"已签收","logisticsInfo":"若已完成取件请忽略"}"#))
    }

    func testAllFormalCarrierNamesRoundTripAndDoNotClearProviderOverride() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: directory.appendingPathComponent("missing"), containerURL: directory)
        _ = try store.snapshot()
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        for carrier in CarrierDetector.allCarriers where carrier != CarrierDetector.unknown {
            XCTAssertEqual(CarrierDetector.carrierMentioned(in: carrier.name), carrier)
        }
        for code in ["kuaijiesudi", "youzhengguonei"] {
            let carrier = try XCTUnwrap(CarrierDetector.allCarriers.first { $0.code == code })
            let value = ShipmentShortcutInput(trackingNumber: "AB123456", carrierName: carrier.name, logisticsInfo: nil, status: nil, logisticsTime: nil)
            _ = try service.upsert(value)
            try store.transaction { data in data.shipments[0].carrierCode = code; data.shipments[0].uapiCarrierCode = "provider-override" }
            _ = try service.upsert(value)
            let after = try XCTUnwrap(store.snapshot().shipments.first)
            XCTAssertEqual(after.carrierCode, code)
            XCTAssertEqual(after.uapiCarrierCode, "provider-override")
        }
    }
}
