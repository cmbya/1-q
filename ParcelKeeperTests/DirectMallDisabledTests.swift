import XCTest
@testable import ParcelKeeper

#if !ENABLE_DIRECT_MALL_IMPORT
final class DirectMallDisabledTests: XCTestCase {
    private func fixture(_ platform: String?) throws -> (URL, SharedPickupStore, Shipment) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        var shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", note: "保留备注", pickupCode: "42", logisticsInfo: "旧轨迹", queryInfo: "旧历史", originPlatform: platform)
        shipment.taobaoOrderID = platform == "pdd" ? nil : "123456789012345678"
        shipment.platformOrderID = platform == "pdd" ? "261102-123456789012345" : nil
        try store.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", source: shipment.note, shipmentID: shipment.id))
        }
        return (root, store, shipment)
    }

    func testDisabledDirectRefreshRetainsRecordsWithoutPaidFallback() async throws {
        // Nil origin with an old Taobao binding is also a legacy direct record.
        for platform in ["taobao", "pdd", nil] as [String?] {
            let (root, store, shipment) = try fixture(platform)
            defer { try? FileManager.default.removeItem(at: root) }
            let paid = TrackingRefreshTests.Client()
            let service = TrackingRefreshService(store: store, client: paid, reloadWidgets: {})
            let records = try store.snapshot().records
            for mode in [TrackingRefreshMode.automatic, .platformOnly] {
                do {
                    _ = try await service.refresh(id: shipment.id, phone: "not-a-phone", mode: mode)
                    XCTFail("Disabled direct services must not run")
                } catch { XCTAssertEqual(error as? TrackingChannelError, .directImportDisabled) }
                var after = try XCTUnwrap(store.snapshot().shipments.first)
                XCTAssertTrue(after.lastRefreshError?.contains("已停用") == true)
                after.lastRefreshError = shipment.lastRefreshError
                XCTAssertEqual(after, shipment)
                XCTAssertEqual(try store.snapshot().records, records)
            }
            XCTAssertEqual(paid.calls, 0)
        }
    }

    func testBatchReportsDisabledDirectRecordsWithoutCharging() async throws {
        for platform in ["taobao", "pdd"] {
            let (root, store, _) = try fixture(platform)
            defer { try? FileManager.default.removeItem(at: root) }
            let paid = TrackingRefreshTests.Client()
            let report = try await TrackingRefreshService(store: store, client: paid, reloadWidgets: {}).refreshPending()
            XCTAssertEqual(report.succeeded, 0)
            XCTAssertEqual(report.failed, 1)
            XCTAssertTrue(report.failures[0].reason.contains("已停用"))
            XCTAssertEqual(report.uapiCount, 0)
            XCTAssertEqual(report.tminiCount, 0)
            XCTAssertEqual(paid.calls, 0)
        }
    }

    func testExplicitUAPIOverrideStillWorksForBothLegacyPlatforms() async throws {
        for platform in ["taobao", "pdd"] {
            let (root, store, shipment) = try fixture(platform)
            defer { try? FileManager.default.removeItem(at: root) }
            let paid = TrackingRefreshTests.Client()
            let service = TrackingRefreshService(store: store, client: paid, reloadWidgets: {})
            _ = try await service.refresh(id: shipment.id, mode: .uapi)
            try service.setRefreshChannel(id: shipment.id, channel: "uapi")
            _ = try await service.refresh(id: shipment.id)
            XCTAssertEqual(paid.calls, 2)
            let after = try XCTUnwrap(store.snapshot().shipments.first)
            XCTAssertEqual(after.logisticsSource, "uapi")
            XCTAssertEqual(after.originPlatform, platform)
            XCTAssertEqual(after.note, shipment.note)
        }
    }

    func testExplicitTminiOverrideStillWorksForBothLegacyPlatforms() async throws {
        let suite = "DirectMallDisabled." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        try settings.saveKey("synthetic"); try settings.setEnabled(true, privacyConfirmed: true)
        let tmini = TminiRoutingTests.Tmini(settings)
        for platform in ["taobao", "pdd"] {
            let (root, store, shipment) = try fixture(platform)
            defer { try? FileManager.default.removeItem(at: root) }
            let paid = TrackingRefreshTests.Client()
            let service = TrackingRefreshService(store: store, client: paid, tminiClient: tmini, reloadWidgets: {})
            _ = try await service.refresh(id: shipment.id, mode: .tmini)
            try service.setRefreshChannel(id: shipment.id, channel: "tmini")
            _ = try await service.refresh(id: shipment.id)
            XCTAssertEqual(paid.calls, 0)
            XCTAssertEqual(try store.snapshot().shipments.first?.logisticsSource, "tmini")
        }
        XCTAssertEqual(tmini.calls, 4)
    }

    func testBackendBindingKeepsPriorityForBothPlatforms() throws {
        for platform in ["taobao", "pdd"] {
            let (root, _, original) = try fixture(platform)
            defer { try? FileManager.default.removeItem(at: root) }
            var shipment = original
            shipment.backendBinding = .init(origin: "https://example.com", accountID: "a", orderID: "o", shipmentID: "s")
            XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment), "kdyzm")
            shipment.refreshChannel = "tmini"
            XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment), "tmini")
            XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment, mode: .platformOnly), "kdyzm")
        }
    }
}
#endif
