import XCTest
@testable import ParcelKeeper

final class SmartShipmentParserTests: XCTestCase {
    func testStationReceiptIsNotRecipientCompletionAndEightDigitCodeIsWhole() throws {
        for receipt in ["已签收，菜鸟驿站代收", "已簽收，豐巢快遞櫃代收"] {
            let draft = try XCTUnwrap(SmartShipmentParser.parse("运单号：YT1234567890123 \(receipt)，取件码：12345678").first)
            XCTAssertEqual(draft.status, .readyForPickup)
            XCTAssertEqual(draft.pickupCode, "12345678")
        }
    }
    func testHyphenCodeAndOversizedCodeNeverTruncated() throws {
        let draft = try XCTUnwrap(SmartShipmentParser.parse("运单号：YT1234567890123 待取件，取件码3-4-1366").first)
        XCTAssertEqual(draft.pickupCode, "3-4-1366")
        let oversized = try XCTUnwrap(SmartShipmentParser.parse("运单号：YT1234567890123 待取件，取件码123456789012345").first)
        XCTAssertEqual(oversized.pickupCode, "")
    }
    func testMultipleParcelsKeepTheirOwnCodeStatusCarrierAndNote() throws {
        let text = "圆通 运单号：YT1234567890123 待取件，取件码12345678 商品：甲商品\n顺丰 运单号：SF1234567890123 已签收 商品：乙商品"
        let drafts = SmartShipmentParser.parse(text)
        XCTAssertEqual(drafts.count, 2)
        let first = try XCTUnwrap(drafts.first { $0.trackingNumber == "YT1234567890123" })
        let second = try XCTUnwrap(drafts.first { $0.trackingNumber == "SF1234567890123" })
        XCTAssertEqual(first.pickupCode, "12345678")
        XCTAssertEqual(first.status, .readyForPickup)
        XCTAssertEqual(first.carrier.code, "yto")
        XCTAssertTrue(first.note.contains("甲商品"))
        XCTAssertFalse(first.note.contains("乙商品"))
        XCTAssertEqual(second.pickupCode, "")
        XCTAssertEqual(second.status, .delivered)
        XCTAssertEqual(second.carrier.code, "sf")
        XCTAssertFalse(second.note.contains("甲商品"))
    }
    func testBlankLineBlocksAreIsolatedButUnseparatedMultilineParcelsAreRejected() {
        let first = "运单号：YT1234567890123\n待取件，取件码12345678"
        let second = "运单号：SF1234567890123\n已签收"
        XCTAssertEqual(SmartShipmentParser.parse(first + "\n\n" + second).count, 2)
        XCTAssertTrue(SmartShipmentParser.parse(first + "\n" + second).isEmpty)
        XCTAssertTrue(SmartShipmentParser.parse("YT1234567890123 SF1234567890123 待取件，取件码12345678").isEmpty)
    }
    func testLatestReturnWinsOverHistoricalReceiptInEitherOrder() throws {
        let events = ["2026-10-29 09:00 已签收", "退回寄件人 2026-10-30 09:00"]
        for history in [events, events.reversed().map { $0 }] {
            let draft = try XCTUnwrap(SmartShipmentParser.parse("运单号：YT1234567890123\n" + history.joined(separator: "\n")).first)
            XCTAssertEqual(draft.status, .exception)
            XCTAssertEqual(draft.pickupCode, "")
        }
    }
    func testNegatedReceiptNoiseAndStationHeaderRegressions() throws {
        for denial in ["非本人签收", "未经收件人签收", "未取件，已签收驿站代收"] {
            let draft = try XCTUnwrap(SmartShipmentParser.parse("运单号 YT1234567890123 " + denial).first)
            XCTAssertNotEqual(draft.status, .delivered, denial)
        }
        XCTAssertTrue(SmartShipmentParser.parse("运单号 YT1234567890123 AB123456 已签收").isEmpty)
        let title = "菜鸟驿站 运单号 YT1234567890123\n2026-10-30 11:00 本人签收"
        XCTAssertEqual(try XCTUnwrap(SmartShipmentParser.parse(title).first).status, .delivered)
        let noise = "运单号 YT1234567890123 待取件，取件码12345678 order:87654321 手机号13800138000 日期20261030"
        let draft = try XCTUnwrap(SmartShipmentParser.parse(noise).first)
        XCTAssertEqual(draft.pickupCode, "12345678")
    }
    func testJSONAndUniqueRepeatedTrackingNumber() throws {
        let json = #"{"trackingNumber":"YT1234567890123","logisticsInfo":"驿站已签收，取件码12345678"}"#
        let draft = try XCTUnwrap(SmartShipmentParser.parse(json).first)
        XCTAssertEqual(draft.status, .readyForPickup)
        XCTAssertEqual(draft.pickupCode, "12345678")
        XCTAssertEqual(SmartShipmentParser.parse("运单号：YT1234567890123\nYT1234567890123 待取件").count, 1)
        XCTAssertNil(SmartShipmentParser.parseSingleNumber("YT1234567890123 http://bad"))
        XCTAssertNil(SmartShipmentParser.parseSingleNumber("13800138000"))
    }
}
