import XCTest
@testable import ParcelKeeper

// Regression specifications written before the fixes. Not executed in the
// Linux/no-build review workflow; run with the iOS XCTest target on macOS.
final class RecognitionReviewRegressionTests: XCTestCase {
    func testMalformedSecondLabeledCodeStillProvesMultiplicity() {
        for text in ["取件码123，取件码(456]", "取件码(456]，取件码123", "取件码123，取件码(456"] {
            let result = PickupTextParser().parse(text)
            XCTAssertEqual(result.candidates.map(\.code), ["123"], text)
            XCTAssertTrue(result.isAmbiguous, text)
            XCTAssertNil(result.candidates.first?.location)
        }
        XCTAssertFalse(PickupTextParser().parse("取件码123，订单号(456]").isAmbiguous)
    }

    func testWrappedOrderFieldsNeverBecomeTrackingButRealTrackingSurvives() {
        for wrapper in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("「", "」"), ("『", "』")] {
            for label in ["订单号", "訂單號", "订单编号", "ORDERID"] {
                let text = "\(label)：\(wrapper.0)AB123456\(wrapper.1) 运单号：SF1234567890123"
                XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: text), ["SF1234567890123"], text)
                XCTAssertEqual(ShipmentShortcutParser.numbers(in: text), ["SF1234567890123"], text)
            }
            XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "运单号：\(wrapper.0)AB123456\(wrapper.1)"), ["AB123456"])
        }
        XCTAssertEqual(Set(CarrierDetector.extractTrackingNumbers(from: "订单号：(AB123456) SF1234567890123 YT1234567890123")), Set(["SF1234567890123", "YT1234567890123"]))
    }

    func testOCRSplitOrderDateCannotSupplyTravelDateOrYear() throws {
        let journey = "车次：G123\n出发站：北京南\n发车时间：09:00\n到达站：上海虹桥"
        for label in ["下单时间", "订单日期", "支付时间", "出票日期", "购票时间"] {
            for value in ["2026-10-31", "2026-10-31\n08:00", "2026-10-31 08:00"] {
                let text = label + "：\n" + value + "\n" + journey
                XCTAssertFalse(TrainTicketRecognition.travelEvidence(text).contains("2026-10-31"), text)
                XCTAssertEqual(try TrainTicketRecognition.parse(text).departureDate, "", text)
            }
        }
        let explicit = "下单时间：\n2025-01-01\n08:00\n出发日期：2026-10-31\n" + journey
        XCTAssertEqual(try TrainTicketRecognition.parse(explicit).departureDate, "2026-10-31")
        XCTAssertEqual(try TrainTicketRecognition.parse("2026-10-31\n" + journey).departureDate, "2026-10-31")
    }

    func testTrainIdentityIsCaseInsensitiveWithoutRewritingLegacyFields() throws {
        let upper = TrainTicketFields(departureDate: "2026-10-31", trainNumber: "G123", departureStation: "北京南", departureTime: "09:00", arrivalStation: "上海虹桥")
        var legacy = upper
        legacy.trainNumber = "g123"
        XCTAssertEqual(legacy.duplicateIdentity, upper.duplicateIdentity)
        XCTAssertEqual(try legacy.validated(), legacy, "Legacy storage validation must remain byte-compatible")
        let decoded = try JSONDecoder().decode(TrainTicketFields.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded, legacy)
        XCTAssertEqual(decoded.duplicateIdentity, upper.duplicateIdentity)
        legacy.trainNumber = "G124"
        XCTAssertNotEqual(legacy.duplicateIdentity, upper.duplicateIdentity)
    }

    func testSmartImportReportsRejectedParcelRatherThanSilentlyDroppingIt() {
        let good = "运单号：YT1234567890123 待取件，取件码123"
        let bad = "{\"trackingNumber\":\"SF1234567890123\",\"logisticsTime\":\"not-a-date\"}"
        let text = good + "\n\n" + bad
        let report = SmartShipmentParser.parseReport(text)
        XCTAssertEqual(report.drafts.map(\.trackingNumber), ["YT1234567890123"])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.trackingNumbers, ["SF1234567890123"])
        XCTAssertFalse(report.failures.first?.message.isEmpty ?? true)
        XCTAssertTrue(report.hasFailures)
        XCTAssertTrue(SmartShipmentParser.parse(text).isEmpty, "Legacy API must fail closed, not disguise partial success")
        XCTAssertEqual(SmartShipmentParser.parse(good).count, 1)
        XCTAssertFalse(SmartShipmentParser.parseReport(good).hasFailures)
        XCTAssertTrue(SmartShipmentParser.parseReport("YT1234567890123 SF1234567890123").hasFailures)
        XCTAssertTrue(SmartShipmentParser.parseReport("没有单号").drafts.isEmpty)
        XCTAssertFalse(SmartShipmentParser.parseReport("没有单号").hasFailures)
    }
}
