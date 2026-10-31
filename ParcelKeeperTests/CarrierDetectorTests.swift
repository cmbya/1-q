import XCTest
@testable import ParcelKeeper

final class CarrierDetectorTests: XCTestCase {
    func testSanitizeAndDetectKnownCarrier() {
        let result = CarrierDetector.detect("sf-1234567890")
        XCTAssertEqual(result.trackingNumber, "SF1234567890")
        XCTAssertEqual(result.carrier.id, "sf")
        XCTAssertEqual(result.confidence, 0.99, accuracy: 0.001)
    }

    func testContextCanOverrideNumberRule() {
        let result = CarrierDetector.detect("SF1234567890", context: "京东物流")
        XCTAssertEqual(result.carrier.id, "jd")
        XCTAssertEqual(result.confidence, 0.87, accuracy: 0.001)
    }

    func testUnknownAndContextOnlyDetection() {
        XCTAssertEqual(CarrierDetector.detect("unrecognized").carrier.id, "unknown")
        XCTAssertEqual(CarrierDetector.detect("unrecognized", context: "韻達").carrier.id, "yunda")
    }

    func testExtractionUsesLocalFieldOwnershipAndStrictTokenBoundaries() {
        let text = "运单号 SF1234567890 order:12345678 手机号13800138000 日期20261030 取件码12345678 code:87654321 AB123456"
        XCTAssertEqual(Set(CarrierDetector.extractTrackingNumbers(from: text)), Set(["SF1234567890", "AB123456"]))
        for text in ["ordertrackingNumber:AB123456", "订单号 AB123456", "_AB123456", "AB123456_", "A-AB123456", "AB123456-Z"] {
            XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: text).isEmpty, text)
        }
        XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "AB123456"), ["AB123456"])
        XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "12345678"), ["12345678"])
    }
    func testOrderNumberVariantsAreNotTrackingNumbers() {
        for label in ["订单号", "訂單號", "订单号码", "訂單號碼", "订单编号", "訂單編號"] {
            for number in ["AB123456", "SF1234567890", "12345678"] {
                XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: "\(label)：\(number)").isEmpty, "\(label):\(number)")
                XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "\(label)：\(number)，运单号：YT9876543210"), ["YT9876543210"])
            }
        }
    }

    func testOrderNumberLabelsDoNotExcludeSeparateTrackingFields() {
        for text in ["订单号码待生成，运单号：AB123456", "訂單號碼待生成，運單號：AB123456",
                     "订单号码：98765432 运单号：AB123456", "訂單號碼：98765432\n運單號：AB123456",
                     "订单号码：AB123456，运单号：AB123456", "AB123456"] {
            XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: text), ["AB123456"], text)
        }
    }

    func testURLTokensAreExcludedWithoutErasingAdjacentTrackingNumbers() {
        for url in ["https://example.test/SF1234567890", "HTTPS://example.test/?trackingNumber=SF1234567890", "www.example.test/12345678"] {
            XCTAssertTrue(CarrierDetector.extractTrackingNumbers(from: url).isEmpty, url)
            XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: "😀 " + url + "，运单号：YT9876543210"), ["YT9876543210"], url)
            XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: url + " SF1234567890"), ["SF1234567890"], url)
        }
    }

    func testExtractionPrioritizesLabelAndDeduplicates() {
        let text = "手机号 13800138000\n运单号 SF1234567890\n运单号 SF1234567890"
        let numbers = CarrierDetector.extractTrackingNumbers(from: text)
        XCTAssertEqual(numbers.first, "SF1234567890")
        XCTAssertEqual(numbers.filter { $0 == "SF1234567890" }.count, 1)
        XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: text, limit: 1), ["SF1234567890"])
    }
}
