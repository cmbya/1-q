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
    func testExtractionPrioritizesLabelAndDeduplicates() {
        let text = "手机号 13800138000\n运单号 SF1234567890\n运单号 SF1234567890"
        let numbers = CarrierDetector.extractTrackingNumbers(from: text)
        XCTAssertEqual(numbers.first, "SF1234567890")
        XCTAssertEqual(numbers.filter { $0 == "SF1234567890" }.count, 1)
        XCTAssertEqual(CarrierDetector.extractTrackingNumbers(from: text, limit: 1), ["SF1234567890"])
    }
}
