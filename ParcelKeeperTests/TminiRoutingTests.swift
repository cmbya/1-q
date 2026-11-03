import XCTest
@testable import ParcelKeeper

final class TminiRoutingTests: XCTestCase {
    final class Tmini: TminiTrackingQuerying {
        let settings: TminiSettingsService
        var calls = 0
        var failure: TminiError?
        var onQuery: (() throws -> Void)?
        init(_ settings: TminiSettingsService) { self.settings = settings }
        func configurationToken() throws -> TminiConfiguration { try settings.configurationToken() }
        func validateConfiguration(_ token: TminiConfiguration) throws { try settings.validateConfiguration(token) }
        func query(trackingNumber: String) async throws -> UAPITrackingResult {
            calls += 1; try onQuery?()
            if let failure { throw failure }
            return UAPITrackingResult(trackingNumber: trackingNumber, carrierName: "", carrierCode: "", status: nil, logisticsInfo: "未知事件", logisticsTime: Date(), queryInfo: "Tmini", queriedAt: Date())
        }
    }
    func testExplicitRoutingPreservesFieldsAndNoUAPIOrPhoneFallback() async throws {
        let suite = "TminiRouting." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        try settings.saveKey("synthetic"); try settings.setEnabled(true, privacyConfirmed: true)
        let tmini = Tmini(settings), uapi = TrackingRefreshTests.Client()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", note: "保留备注", pickupCode: "42", reminderDate: Date().addingTimeInterval(3600))
        try store.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", source: "保留备注", shipmentID: shipment.id))
        }
        let service = TrackingRefreshService(store: store, client: uapi, tminiClient: tmini, reloadWidgets: {})
        try service.setRefreshChannel(id: shipment.id, channel: "tmini")
        _ = try await service.refresh(id: shipment.id, phone: "not-a-phone")
        XCTAssertEqual(tmini.calls, 1); XCTAssertEqual(uapi.calls, 0)
        var after = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(after.logisticsSource, "tmini")
        XCTAssertEqual(after.note, shipment.note); XCTAssertEqual(after.pickupCode, shipment.pickupCode)
        XCTAssertEqual(after.reminderDate, shipment.reminderDate); XCTAssertEqual(after.status, shipment.status)
        // Config changes during query cannot write a late success.
        tmini.onQuery = { try settings.saveKey("replacement") }
        do { _ = try await service.refresh(id: shipment.id, mode: .tmini); XCTFail("Expected stale configuration") }
        catch { XCTAssertEqual(error as? TminiError, .configurationChanged) }
        after = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(after.logisticsInfo, "未知事件")
        XCTAssertEqual(uapi.calls, 0)
        // No fallback even when an explicitly selected provider fails.
        tmini.onQuery = nil; tmini.failure = .quota
        try store.transaction { data in
            var second = shipment; second.id = UUID(); second.trackingNumber = "YT2234567890123"; second.refreshChannel = "tmini"; second.pickupCode = "43"
            data.shipments.append(second)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "43", shipmentID: second.id))
        }
        let priorCalls = tmini.calls
        let report = try await service.refreshPending(mode: .tmini)
        XCTAssertEqual(tmini.calls - priorCalls, 1)
        XCTAssertEqual(report.failed, 1); XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(uapi.calls, 0)
        // Legacy automatic routing remains UAPI when the explicit per-ticket setting is cleared.
        try service.setRefreshChannel(id: shipment.id, channel: nil)
        uapi.result = UAPITrackingResult(trackingNumber: shipment.trackingNumber, carrierName: "", carrierCode: "", status: nil, logisticsInfo: "旧默认渠道", logisticsTime: Date().addingTimeInterval(1), queryInfo: "UAPI", queriedAt: Date().addingTimeInterval(1))
        _ = try await service.refresh(id: shipment.id, mode: .automatic)
        XCTAssertEqual(uapi.calls, 1)
        XCTAssertEqual(QueryChannelChoice.tmini.mode, .tmini)
        XCTAssertEqual(Optional<QueryChannelChoice>.none.resolvedMode, .automatic)
    }
}
