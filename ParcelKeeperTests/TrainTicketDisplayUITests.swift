import Foundation
import XCTest

/// Source-contract checks only: these do not launch the app or prove SwiftUI interaction behavior.
final class TrainTicketDisplayUITests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("ParcelKeeper/Views/TrainTicketViews.swift"), encoding: .utf8)
    }

    func testNewTicketStartsDisabledAndEditorSavesExplicitWindow() throws {
        let text = try source()
        XCTAssertTrue(text.contains("enabled: ticket != nil, startsAt: ticket?.widgetStartsAt, endsAt: nil"))
        XCTAssertTrue(text.contains("store.saveTrainTicket(validated, existing: original, displayWindow: displayWindow)"))
        XCTAssertTrue(text.contains("确认上方时间为展示开始"))
        XCTAssertTrue(text.contains(".environment(\\.timeZone, trainTicketBeijingTimeZone)"))
        XCTAssertFalse(text.contains("setTrainTicketKeepVisible"))
    }

    func testRecognitionOnlyAssignsTicketFields() throws {
        let text = try source()
        let start = try XCTUnwrap(text.range(of: "@MainActor private func recognize()"))
        let end = try XCTUnwrap(text.range(of: "    private func save()", range: start.upperBound..<text.endIndex))
        let recognition = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(recognition.contains("fields = result"))
        XCTAssertFalse(recognition.contains("displayWindow ="))
        XCTAssertFalse(recognition.contains("customEnd ="))
        XCTAssertTrue(recognition.contains("!Task.isCancelled, recognitionID == requestID"))
        XCTAssertTrue(text.contains(".disabled(busy || store.isHistoricalSnapshot)"))
    }

    func testBatchRequiresExplicitConfirmationAndUsesSnapshotAPI() throws {
        let text = try source()
        XCTAssertTrue(text.contains("@State private var tickets: [TrainTicket]"))
        XCTAssertTrue(text.contains("本次统一开启显示，结束恢复跟随各票到达时间"))
        XCTAssertTrue(text.contains("selected.allSatisfy({ $0.fields.arrival != nil })"))
        XCTAssertTrue(text.contains("selectedIDs.isEmpty || !confirmed || store.isHistoricalSnapshot"))
        XCTAssertTrue(text.contains("store.setTrainTicketDisplayWindow(window, for: selected)"))
    }

    func testWidgetSettingsProtectBrowsingBaselineAndClearBrowsingOnSave() throws {
        let text = try source()
        XCTAssertTrue(text.contains("current.browsingTicketID == baselineBrowsingTicketID"))
        XCTAssertTrue(text.contains("ticketID: mode == .fixed ? ticketID : nil, browsingTicketID: nil"))
        XCTAssertTrue(text.contains("browsingTicketID: baselineBrowsingTicketID"))
        XCTAssertTrue(text.contains("saved.browsingTicketID == binding.browsingTicketID"))
    }
}
