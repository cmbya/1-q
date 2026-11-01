import XCTest
@testable import ParcelKeeper

final class TrainDatePickerTests: XCTestCase {
    func testPickerUsesBeijingAndPreservesCanonicalStorage() {
        let instant = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(TrainDateInput.value(instant, isDate: true), "1970-01-01")
        XCTAssertEqual(TrainDateInput.value(instant, isDate: false), "08:00")
        XCTAssertEqual(TrainDateInput.displayDay("2026-11-02"), "2026年11月2日")
    }
    func testPartialMissingYearIsNeverRepairedByDisplay() {
        XCTAssertEqual(TrainDateInput.displayDay(""), "")
        XCTAssertEqual(TrainDateInput.displayDay("11-02"), "11-02")
        XCTAssertNil(TrainDateInput.parsed("2026-02-30", isDate: true))
        XCTAssertNil(TrainDateInput.parsed("25:70", isDate: false))
    }
    func testStoredValuesRoundTripIndependently() {
        for day in ["2024-02-29", "2026-12-31"] {
            let parsed = TrainDateInput.parsed(day, isDate: true)
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed.map { TrainDateInput.value($0, isDate: true) }, day)
        }
        for time in ["00:00", "23:59"] {
            let parsed = TrainDateInput.parsed(time, isDate: false)
            XCTAssertEqual(parsed.map { TrainDateInput.value($0, isDate: false) }, time)
        }
    }
}
