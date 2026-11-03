import XCTest
@testable import ParcelKeeper

final class RefreshOutcomeTests: XCTestCase {
    func testQueuedSummaryIsSeparateFromFailures() {
        var report = TrackingRefreshReport()
        report.queued.append(.init(trackingNumber: "YT1234567890123", reason: "等待后台任务"))
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.message.contains("排队 1 票"))
        XCTAssertTrue(report.message.contains("失败 0 票"))
    }
    func testTaobaoNeverRoutesToUAPIJustBecauseBindingIsMissing() throws {
        var shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", originPlatform: "taobao")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment), "taobao")
        shipment.backendBinding = .init(origin: "https://example.com", accountID: "a", orderID: "o", shipmentID: "s")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment), "kdyzm")
        shipment.refreshChannel = "uapi"
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment), "uapi")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment, mode: .platformOnly), "kdyzm")
        XCTAssertEqual(try TrackingRefreshService.resolvedChannel(shipment, mode: .tmini), "tmini")
    }
    func testSafeDiagnosticReasonsAndBoundedRouteFlags() {
        XCTAssertEqual(TrackingRefreshService.diagnosticReason(ShipmentShortcutError.olderUpdate), .olderEvent)
        XCTAssertEqual(TrackingRefreshService.diagnosticReason(KDYZMError.queued), .queued)
        XCTAssertEqual(TrackingRefreshService.diagnosticReason(TminiError.configurationChanged), .configurationChanged)
        XCTAssertEqual(DiagnosticMetric.hasBackendBinding.bounded(10000), 1)
        XCTAssertEqual(DiagnosticMetric.forcedPaidMode.bounded(-1), 0)
        let shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto")
        XCTAssertEqual(TrackingRefreshService.routingDiagnostics(shipment, mode: .tmini)[.forcedPaidMode], 1)
    }
    func testQueuedBackendBatchRetainsJobWithoutPaidFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        var shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", originPlatform: "taobao", platformOrderID: "platform-order")
        let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
        shipment.backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
        try store.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "", source: "", shipmentID: shipment.id))
        }
        let transport = KDYZMNetworkTests.Transport()
        transport.responses = [(Data("{\"accepted\":true,\"jobs\":[{\"id\":\"j\",\"accountId\":\"a\",\"orderId\":\"o\",\"state\":\"queued\",\"createdAt\":200000,\"retryAt\":4102444800000}]}".utf8), 202)]
        let keys = KDYZMNetworkTests.Keys(); keys.value = credential
        let client = KDYZMClient(transport: transport)
        let paid = TrackingRefreshTests.Client()
        var service = TrackingRefreshService(store: store, client: paid, reloadWidgets: {})
        service.backendConnection = KDYZMConnection(keys: keys, client: client)
        service.backendClient = client
        let report = try await service.refreshPending()
        XCTAssertEqual(report.queued.count, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.succeeded, 0)
        XCTAssertEqual(paid.calls, 0)
        XCTAssertEqual(try store.snapshot().shipments.first?.backendRefreshJobID, "j")
        XCTAssertEqual(transport.requests.count, 1)
    }
}
