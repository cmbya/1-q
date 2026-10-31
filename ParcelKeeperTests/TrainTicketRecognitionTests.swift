import XCTest
@testable import ParcelKeeper

final class TrainTicketRecognitionTests: XCTestCase {
    static let labeled = """
    出发日期：2026年05月01日
    车次：G311
    出发站：北京西
    发车时间：11:05
    到达站：南宁东
    到达日期：2026-05-01
    到达时间：21:08
    车厢：02
    座位：05A
    席别：二等座
    检票口：6B
    乘车人：姜**
    """
    static let inline = "订单详情 下单时间：2026-04-25 22:07 乘车日期：2026-05-01 车次：G311 出发站：北京西 发车时间：11:05 到达站：南宁东 到达日期：2026-05-01 到达时间：21:08 车厢：02 座位：05A 席别：二等座 检票口：6B 乘车人：姜**"

    func testInlineOrderTimestampPreservesTravelFieldsAndStopsBeforeIdentity() throws {
        let expected = try TrainTicketRecognition.parse(Self.labeled)
        XCTAssertEqual(try TrainTicketRecognition.parse(Self.inline), expected)
        XCTAssertEqual(try TrainTicketRecognition.parse(Self.inline + " 身份证号：123456789012345678"), expected)
        let evidence = TrainTicketRecognition.travelEvidence(Self.inline)
        XCTAssertFalse(evidence.contains("2026-04-25"))
        XCTAssertFalse(evidence.contains("22:07"))
        XCTAssertTrue(evidence.contains("2026-05-01"))
        XCTAssertTrue(evidence.contains("11:05"))
        let missingYear = Self.inline.replacingOccurrences(of: "2026-05-01", with: "5月1日")
        XCTAssertEqual(try TrainTicketRecognition.parse(missingYear).departureDate, "")
    }

    func testPassengerListsRejectedButEnglishAndMaskedNamesPreserved() throws {
        for name in ["张三 李四", "张三，李四", "张三,李四", "张三、李四", "姜** 张**"] {
            let raw = Self.labeled.replacingOccurrences(of: "姜**", with: name)
            XCTAssertThrowsError(try TrainTicketRecognition.parse(raw)) { error in
                guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") }
            }
        }
        for name in ["John Smith", "姜**", "姜＊＊"] {
            XCTAssertEqual(try TrainTicketRecognition.parse(Self.labeled.replacingOccurrences(of: "姜**", with: name)).passenger, name)
        }
    }

    func testLabeledAllFields() throws {
        let f = try TrainTicketRecognition.parse(Self.labeled)
        XCTAssertEqual(f.departureDate, "2026-05-01")
        XCTAssertEqual(f.trainNumber, "G311")
        XCTAssertEqual(f.departureStation, "北京西")
        XCTAssertEqual(f.arrivalStation, "南宁东")
        XCTAssertEqual(f.departureTime, "11:05")
        XCTAssertEqual(f.arrivalDate, "2026-05-01")
        XCTAssertEqual(f.arrivalTime, "21:08")
        XCTAssertEqual(f.carriage, "02")
        XCTAssertEqual(f.seat, "05A")
        XCTAssertEqual(f.seatClass, "二等座")
        XCTAssertEqual(f.gate, "6B")
        XCTAssertEqual(f.passenger, "姜**")
        XCTAssertNoThrow(try f.validated())
    }
    func testOCRMissingYearRemainsDraftAndDoesNotUseOrderDate() throws {
        let f = try TrainTicketRecognition.parse("下单时间：2026-04-01 08:00\n5月01日周五\n北京西11:05\nG311\n南宁东21:08\n02车05A号二等座\n检票口6B\n乘车人姜**")
        XCTAssertEqual(f.departureDate, "")
        XCTAssertEqual(f.departureStation, "北京西")
        XCTAssertEqual(f.arrivalStation, "南宁东")
        XCTAssertEqual(f.departureTime, "11:05")
        XCTAssertEqual(f.seat, "05A")
        XCTAssertEqual(f.arrivalDate, "")
        XCTAssertEqual(f.arrivalTime, "21:08")
        XCTAssertThrowsError(try f.validated())
    }
    func testOCRSleeperAndSeparateSeatClass() throws {
        let raw = "2026年05月01日\n北京西11:05\nG311\n南宁东21:08\n软卧\n02车05号下铺\n检票口6B\n乘车人姜**"
        let fields = try TrainTicketRecognition.parse(raw)
        XCTAssertEqual(fields.carriage, "02")
        XCTAssertEqual(fields.seat, "05号下铺")
        XCTAssertEqual(fields.seatClass, "软卧")
    }
    func testOvernightExplicitDate() throws {
        let text = Self.labeled.replacingOccurrences(of: "2026-05-01", with: "2026-05-02").replacingOccurrences(of: "21:08", with: "01:08")
        XCTAssertNoThrow(try TrainTicketRecognition.parse(text).validated())
    }
    func testAmbiguousAndUnreliableRejected() {
        for text in ["你好", Self.labeled + "\n车次：D123", Self.labeled + "\n乘车人：张三", Self.labeled + "\n" + Self.labeled, Self.labeled + "\n02车05A号二等座\n03车06B号二等座"] {
            XCTAssertThrowsError(try TrainTicketRecognition.parse(text))
        }
    }
    func testShortcutWriterAppendsRejectsDuplicatesAndIncompleteDrafts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, containerURL: root)
        let before = try store.snapshot()
        let fields = try TrainTicketRecognition.parse(Self.labeled)
        var reloads = 0
        let saved = try TrainTicketWriter.save(fields, to: store) { reloads += 1 }
        let after = try store.snapshot()
        XCTAssertEqual(after.trainTickets?.map(\.id), [saved.id])
        XCTAssertEqual(saved.displayWindow?.enabled, false)
        XCTAssertFalse(saved.isWidgetVisible(at: try XCTUnwrap(saved.fields.departure)))
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(after.shipments, before.shipments)
        XCTAssertThrowsError(try TrainTicketWriter.save(fields, to: store) { reloads += 1 })
        var draft = fields; draft.departureDate = ""
        XCTAssertThrowsError(try TrainTicketWriter.save(draft, to: store) { reloads += 1 })
        XCTAssertEqual(try store.snapshot(), after)
        XCTAssertEqual(reloads, 1)
    }
    func testShortcutWriterNeverInitializesSharedStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, containerURL: root, accessMode: .existingSharedData)
        XCTAssertThrowsError(try TrainTicketWriter.save(TrainTicketRecognition.parse(Self.labeled), to: store) {})
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testAIDirectAlsoRejectsStructuralPassengerLists() async throws {
        let raw = Self.labeled.replacingOccurrences(of: "姜**", with: "张三 李四")
        do {
            _ = try await TrainTicketRecognition.recognize(raw, useAI: true) { _ in
                XCTFail("Structural ambiguity must stop before AI"); return TrainTicketFields()
            }
            XCTFail("Must reject passenger list")
        } catch { guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") } }
        do {
            _ = try await TrainTicketRecognition.recognize("未标记乘客的行程", useAI: true) { _ in
                var fields = TrainTicketFields(); fields.passenger = "张三 李四"; return fields
            }
            XCTFail("Must reject multi-name AI field")
        } catch { guard case TrainTicketRecognitionError.ambiguous = error else { return XCTFail("\(error)") } }
    }

    func testAIDirectBypassesLocalAndNoFallback() async throws {
        var calls = 0
        var expected = TrainTicketFields(); expected.trainNumber = "G999"
        let result = try await TrainTicketRecognition.recognize("本地不认识的语义", useAI: true) { raw in
            calls += 1; XCTAssertEqual(raw, "本地不认识的语义"); return expected
        }
        XCTAssertEqual(result, expected); XCTAssertEqual(calls, 1)
        do {
            _ = try await TrainTicketRecognition.recognize(Self.labeled, useAI: true) { _ in throw AIServiceError.unavailable }
            XCTFail("AI errors must not fall back")
        } catch { XCTAssertEqual(error as? AIServiceError, .unavailable) }
        _ = try await TrainTicketRecognition.recognize(Self.labeled, useAI: false) { _ in XCTFail("AI disabled"); return expected }
        XCTAssertEqual(calls, 1)
    }
}
