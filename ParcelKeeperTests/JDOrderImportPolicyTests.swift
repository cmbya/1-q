import XCTest
@testable import ParcelKeeper

final class JDOrderImportPolicyTests: XCTestCase {
    private func date(_ text: String) -> Date { JDOrderImportPolicy.submittedDate(text)! }
    func testThirtyShanghaiCalendarDaysInclusiveTodayAndNotRollingSeconds() {
        let policy = JDOrderImportPolicy(now: date("2026-11-04 15:30:00"))
        XCTAssertTrue(policy.contains(date("2026-10-06 00:00:00")))
        XCTAssertFalse(policy.contains(date("2026-10-05 23:59:59")))
        XCTAssertTrue(policy.contains(date("2026-11-04 23:59:59")))
        XCTAssertFalse(policy.contains(date("2026-11-05 00:00:00")))
        XCTAssertTrue(policy.contains(date("2026-10-15 12:00:00")))
    }
    func testStrictTrustedSubmitDateAndTimezone() {
        XCTAssertEqual(date("2026-10-15 12:00:00"), date("2026-10-15T04:00:00Z"))
        XCTAssertEqual(date("2026-10-15"), date("2026-10-15 00:00:00"))
        for value in ["", "2026-02-30 10:00:00", "2026-13-01", "昨天", "2026-10-15garbage", "2026-10-15T12:00:00+99:99"] {
            XCTAssertNil(JDOrderImportPolicy.submittedDate(value))
        }
        XCTAssertNil(JDOrderImportPolicy.submittedDate(true))
    }
    func testReportPartitionsOrderCountsAndNeverClaimsEmptyOrdersImported() {
        var report = JDOrderImportReport()
        let policy = JDOrderImportPolicy(now: date("2026-11-04"))
        XCTAssertTrue(report.consider(submittedAt: date("2026-10-15"), excluded: false, policy: policy))
        XCTAssertFalse(report.consider(submittedAt: nil, excluded: false, policy: policy))
        XCTAssertFalse(report.consider(submittedAt: nil, excluded: true, policy: policy))
        XCTAssertFalse(report.consider(submittedAt: date("2026-10-05"), excluded: false, policy: policy))
        report.withoutWaybill = 1; report.limited = true
        XCTAssertEqual(report.scanned, 4)
        XCTAssertEqual(report.scanned, report.eligible + report.excluded + report.missingDate + report.outsideWindow)
        XCTAssertTrue(report.message.contains("暂无真实运单"))
        XCTAssertTrue(report.message.contains("暂无法生成快递"))
        XCTAssertTrue(report.message.contains("未读完"))
        XCTAssertFalse(report.message.contains("已导入"))
        XCTAssertFalse(report.message.contains("全量"))
    }
    func testExclusionsNeedBusinessEvidenceNotDeliveryProductTextOrUnknownNumericTypes() {
        XCTAssertFalse(JDOrderImportPolicy.excluded(orderType: "999", allVirtual: false, evidence: "已签收"))
        XCTAssertFalse(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: "配送中"))
        for text in ["京东外卖 已完成", "京东秒送 已签收", "虚拟订单", "生活服务"] {
            XCTAssertTrue(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: text))
        }
    }
}
