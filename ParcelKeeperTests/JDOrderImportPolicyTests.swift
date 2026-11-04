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
    private func parcel(_ number: String) -> MallWebDetail {
        MallWebDetail(number: number, carrier: "京东快递", points: [MallWebPoint(date: date("2026-11-01 10:00:00"), text: "运输中")])
    }
    private func eligibleReport(_ count: Int) -> JDOrderImportReport {
        var report = JDOrderImportReport()
        let policy = JDOrderImportPolicy(now: date("2026-11-04"))
        for _ in 0..<count { _ = report.consider(submittedAt: date("2026-10-15"), excluded: false, policy: policy) }
        return report
    }
    func testAfterSalesServiceIsNotAServiceBusiness() {
        for evidence in ["售后服务中", "售后服务完成", "客户服务处理中", "已签收 售后服务"] {
            XCTAssertFalse(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: evidence))
        }
        for evidence in ["服务订单", "生活服务", "虚拟业务", "虚拟订单"] {
            XCTAssertTrue(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: evidence))
        }
    }
    func testAppendCarriesExactlyItsOwnParcelPreview() throws {
        var report = eligibleReport(1)
        try report.append([parcel("JD123456789"), parcel("SF123456789")], orderID: "123456789012", title: "购物", url: "")
        XCTAssertEqual(report.candidates.map { $0.previewDetail?.number }, ["JD123456789", "SF123456789"])
        XCTAssertEqual(report.candidates.first?.previewDetail?.points.first?.text, "运输中")
    }
    func testCrossOrderAmbiguityRemovesBothSidesAndCannotReappear() throws {
        var report = eligibleReport(4)
        for id in ["123456789012", "123456789013", "123456789014"] {
            try report.append([parcel("JD123456789")], orderID: id, title: "购物", url: "")
        }
        try report.append([parcel("SF123456789")], orderID: "123456789015", title: "购物", url: "")
        try report.append([], orderID: "123456789012", title: "购物", url: "")
        XCTAssertEqual(report.detailFailed, 3); XCTAssertEqual(report.withoutWaybill, 0)
        XCTAssertEqual(report.candidates.map(\.trackingNumber), ["SF123456789"])
        XCTAssertEqual(report.detailFailed, 3)
        XCTAssertEqual(report.withoutWaybill, 0)
        XCTAssertEqual(report.unreadDetails, 0)
        XCTAssertEqual(report.eligible, report.numberedOrders + report.withoutWaybill + report.detailFailed + report.unreadDetails)
        XCTAssertTrue(report.message.contains("身份冲突"))
    }
    func testAmbiguousParcelDoesNotDoubleCountOrderWithAnotherSafeParcel() throws {
        var report = eligibleReport(2)
        try report.append([parcel("JD123456789"), parcel("SF123456789")], orderID: "123456789012", title: "购物", url: "")
        try report.append([parcel("JD123456789")], orderID: "123456789013", title: "购物", url: "")
        XCTAssertEqual(report.candidates.map(\.trackingNumber), ["SF123456789"])
        XCTAssertEqual(report.detailFailed, 1); XCTAssertEqual(report.numberedOrders, 1)
        XCTAssertEqual(report.unreadDetails, 0)
    }
    func testRepeatedAppendAndFailuresDoNotDoubleCountOrderOutcomes() throws {
        var report = eligibleReport(3)
        try report.append([], orderID: "123456789012", title: "购物", url: "")
        try report.append([], orderID: "123456789012", title: "购物", url: "")
        report.recordDetailFailure(orderID: "123456789013")
        report.recordDetailFailure(orderID: "123456789013")
        XCTAssertEqual(report.withoutWaybill, 1); XCTAssertEqual(report.detailFailed, 1)
        XCTAssertEqual(report.unreadDetails, 1)
        report.stoppedReason = .verification; report.limited = true
        XCTAssertTrue(report.message.contains("详情读取失败或身份冲突"))
        XCTAssertTrue(report.message.contains("尚未读取详情"))
        XCTAssertTrue(report.message.contains("验证或风控"))
        XCTAssertFalse(report.message.contains("SECRET"))
    }
    func testSummaryIncludesAllClassificationCountsAndSafeStopWithoutIdentifiers() throws {
        var report = eligibleReport(3)
        try report.append([], orderID: "123456789012", title: "SECRET", url: "https://example.test/SECRET")
        report.recordDetailFailure(orderID: "123456789013")
        report.stoppedReason = .verification; report.limited = true
        report.missingDate = 1; report.excluded = 2; report.outsideWindow = 3; report.scanned += 6
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let diagnostics = JDDiagnostics(.jdFetch, log: log)
        // The aggregate must survive normal per-event flood suppression.
        for _ in 0..<25 { diagnostics.event(.jdResponseAccepted) }
        report.logSummary(diagnostics)
        let text = log.snapshotForTesting().text
        for expected in ["jdMissingDate=1", "jdBusinessExcluded=2", "jdOutsideWindow=3", "jdDetailFailed=1", "jdWithoutWaybill=1", "jdLimited=1", "reason=verification"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("123456789012")); XCTAssertFalse(text.contains("SECRET"))
        XCTAssertEqual(report.scanned, report.eligible + report.missingDate + report.excluded + report.outsideWindow)
        XCTAssertEqual(report.eligible, report.numberedOrders + report.withoutWaybill + report.detailFailed + report.unreadDetails)
    }
    func testExclusionsNeedBusinessEvidenceNotDeliveryProductTextOrUnknownNumericTypes() {
        XCTAssertFalse(JDOrderImportPolicy.excluded(orderType: "999", allVirtual: false, evidence: "已签收"))
        XCTAssertFalse(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: "配送中"))
        for text in ["京东外卖 已完成", "京东秒送 已签收", "虚拟订单", "生活服务"] {
            XCTAssertTrue(JDOrderImportPolicy.excluded(orderType: "", allVirtual: false, evidence: text))
        }
    }
}
