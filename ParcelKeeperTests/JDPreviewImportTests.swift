import XCTest
@testable import ParcelKeeper

/// Native XCTest coverage. Linux source-contract checks are not a substitute for running this suite.
@MainActor
final class JDPreviewImportTests: XCTestCase {
    private let number = "JD1234567890123"
    private let order = "123456789012"
    private let eventTime = Date(timeIntervalSince1970: 1700000000)

    private final class Keys: AIKeyStore {
        var value: String?
        func read() throws -> String? { value }
        func save(_ value: String) throws { self.value = value }
        func delete() throws { value = nil }
        func read(endpoint: String) throws -> String? { try read() }
        func save(_ value: String, endpoint: String) throws { try save(value) }
        func delete(endpoint: String) throws { try delete() }
    }
    private final class Mall: MallTrackingQuerying {
        var calls = 0
        var sourceURL: String?
        func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
            calls += 1
            throw MallWebError.unsupported
        }
        func query(platform: String, orderID: String, trackingNumber: String, sourceURL: String?) async throws -> UAPITrackingResult {
            self.sourceURL = sourceURL
            calls += 1
            return UAPITrackingResult(trackingNumber: trackingNumber, carrierName: "京东物流", carrierCode: "", status: .readyForPickup, logisticsInfo: "已送达驿站", logisticsTime: nil, queryInfo: "旧单显式刷新", queriedAt: Date())
        }
    }
    private func fixture() throws -> (URL, SharedPickupStore, ShipmentStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        return (root, shared, ShipmentStore(storageProvider: { shared }))
    }
    private var entry: String { "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=\(order)&orderType=0" }
    private func candidate(_ text: String = "已送达驿站，请凭取件码取件") -> MallCandidate {
        MallCandidate(trackingNumber: number, carrier: "京东物流", title: "本次订单", orderID: order, sourceURL: entry,
                      previewDetail: MallWebDetail(number: number, carrier: "京东物流", points: [MallWebPoint(date: eventTime, text: text)]))
    }
    private func service(_ shared: SharedPickupStore, paid: TrackingRefreshTests.Client, mall: Mall) -> TrackingRefreshService {
        TrackingRefreshService(store: shared, client: paid, reloadWidgets: {}, mallClient: mall)
    }
    private func add(_ app: ShipmentStore, status: ShipmentStatus = .inTransit) throws -> Shipment {
        let item = Shipment(trackingNumber: number, carrierName: "京东物流", carrierCode: "jd", status: status,
                            note: "用户备注", pickupCode: "42", reminderDate: eventTime,
                            logisticsInfo: "旧轨迹", logisticsTime: .distantFuture, queryInfo: "旧历史", uapiCarrierCode: "old-provider",
                            originPlatform: "jd", platformOrderID: order, platformLogisticsURL: entry)
        try app.addThrowing(item)
        return item
    }

    func testUnqueriedJDNumberOnlyImportNeverPresentsDefaultAsVerifiedMovement() {
        var item = Shipment(trackingNumber: number, carrierName: "京东物流", carrierCode: "jd", originPlatform: "jd", platformOrderID: order)
        XCTAssertEqual(item.statusDisplayText, "物流状态未核实")
        item.lastQueriedAt = eventTime
        XCTAssertEqual(item.statusDisplayText, "运输中")
        item.lastQueriedAt = nil; item.status = .readyForPickup
        XCTAssertEqual(item.statusDisplayText, "待取件")
        item.status = .inTransit; item.originPlatform = "pdd"
        XCTAssertEqual(item.statusDisplayText, "运输中")
    }
    func testNewImportPersistsExactPreviewWithoutAnyQuery() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = candidate()
        let id = try app.importMall(value, platform: "jd")
        let paid = TrackingRefreshTests.Client(), mall = Mall()
        XCTAssertFalse(try service(shared, paid: paid, mall: mall).applyMallPreview(id: id, candidate: value, expectedGeneration: MallSession.generation(for: .jd)))
        let saved = try XCTUnwrap(shared.snapshot().shipments.first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.logisticsInfo, value.previewDetail?.points.first?.text)
        XCTAssertEqual(saved.logisticsTime, eventTime)
        XCTAssertEqual(saved.status, .readyForPickup)
        XCTAssertEqual(saved.logisticsSource, "jd")
        XCTAssertEqual(saved.platformLogisticsURL, entry)
        XCTAssertNotNil(saved.lastQueriedAt)
        XCTAssertEqual(paid.calls, 0); XCTAssertEqual(mall.calls, 0)
        XCTAssertEqual(try shared.snapshot().records.filter { $0.shipmentID == id }.count, 1)
    }

    func testExistingPreviewPreservesUserFieldsHistoryAndManualCompletionDespiteOlderEvent() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app)
        let record = try XCTUnwrap(app.pickupRecords.first)
        try app.setPickupCompleted(id: record.id, completed: true)
        let id = try app.importMall(candidate(), platform: "jd")
        _ = try app.applyMallPreview(id: id, candidate: candidate(), expectedGeneration: MallSession.generation(for: .jd))
        let data = try shared.snapshot(), saved = try XCTUnwrap(shared.snapshot().shipments.first)
        XCTAssertEqual(id, old.id); XCTAssertEqual(saved.createdAt, old.createdAt)
        XCTAssertEqual(saved.note, old.note); XCTAssertEqual(saved.pickupCode, old.pickupCode)
        XCTAssertEqual(saved.reminderDate, old.reminderDate); XCTAssertEqual(saved.uapiCarrierCode, old.uapiCarrierCode)
        XCTAssertEqual(saved.logisticsTime, eventTime)
        XCTAssertTrue(saved.queryInfo?.contains("旧历史") == true)
        XCTAssertTrue(saved.queryInfo?.contains("已送达驿站") == true)
        XCTAssertEqual(data.records.first?.id, record.id)
        XCTAssertTrue(try XCTUnwrap(data.records.first).isCompleted)
    }

    func testRecipientCollectionCompletesButRepeatedDeliveredPreviewDoesNotUndoManualRestore() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app)
        let value = candidate("本人已取件")
        let generation = MallSession.generation(for: .jd)
        XCTAssertTrue(try app.applyMallPreview(id: old.id, candidate: value, expectedGeneration: generation))
        let record = try XCTUnwrap(app.pickupRecords.first)
        XCTAssertTrue(record.isCompleted)
        try app.setPickupCompleted(id: record.id, completed: false)
        XCTAssertFalse(try app.applyMallPreview(id: old.id, candidate: value, expectedGeneration: generation))
        XCTAssertFalse(try XCTUnwrap(shared.snapshot().records.first).isCompleted)
    }

    func testArchivedAndDeliveredRegressionCannotOverwrite() throws {
        for status in [ShipmentStatus.archived, .delivered] {
            let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let old = try add(app, status: status), before = try shared.snapshot()
            XCTAssertThrowsError(try app.applyMallPreview(id: old.id, candidate: candidate(), expectedGeneration: MallSession.generation(for: .jd)))
            XCTAssertEqual(try shared.snapshot(), before)
        }
    }

    func testNoTraceOnlySavesAssociationWithoutClaimingLogisticsSuccessOrQuerying() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var value = candidate(); value.previewDetail = nil
        let id = try app.importMall(value, platform: "jd"), before = try shared.snapshot()
        let paid = TrackingRefreshTests.Client(), mall = Mall()
        XCTAssertThrowsError(try service(shared, paid: paid, mall: mall).applyMallPreview(id: id, candidate: value, expectedGeneration: MallSession.generation(for: .jd))) {
            XCTAssertEqual($0 as? MallWebError, .noTrace)
        }
        XCTAssertEqual(try shared.snapshot(), before)
        XCTAssertNil(before.shipments.first?.lastQueriedAt)
        XCTAssertNil(before.shipments.first?.logisticsSource)
        XCTAssertEqual(paid.calls, 0); XCTAssertEqual(mall.calls, 0)
        value.previewDetail = MallWebDetail(number: number, carrier: "京东物流", points: [])
        XCTAssertThrowsError(try app.applyMallPreview(id: id, candidate: value, expectedGeneration: MallSession.generation(for: .jd)))
        XCTAssertEqual(try shared.snapshot(), before)
    }

    func testPreviewCannotOverrideBackendOrExplicitPaidChannelAndDoesNotQuery() throws {
        for channel in ["backend", "uapi", "tmini"] {
            let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let old = try add(app)
            try shared.transaction { data in
                if channel == "backend" {
                    data.shipments[0].backendBinding = KDYZMBinding(origin: "https://example.invalid", accountID: "a", orderID: "o", shipmentID: "s")
                } else { data.shipments[0].refreshChannel = channel }
            }
            let id = try app.importMall(candidate(), platform: "jd")
            XCTAssertEqual(id, old.id)
            let before = try shared.snapshot(), paid = TrackingRefreshTests.Client(), mall = Mall()
            XCTAssertThrowsError(try service(shared, paid: paid, mall: mall).applyMallPreview(id: id, candidate: candidate(), expectedGeneration: MallSession.generation(for: .jd)))
            XCTAssertEqual(try shared.snapshot(), before)
            XCTAssertEqual(paid.calls, 0); XCTAssertEqual(mall.calls, 0)
        }
    }

    func testAccountGenerationChangeRejectsPreviewWithoutDiskChanges() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app), generation = MallSession.generation(for: .jd)
        try MallSession(platform: .jd, keys: Keys()).clear()
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.applyMallPreview(id: old.id, candidate: candidate(), expectedGeneration: generation)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try shared.snapshot(), before)
    }

    func testWrongWaybillOrderURLOrCarrierRejectsWithoutOverwriting() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app), before = try shared.snapshot(), generation = MallSession.generation(for: .jd)
        var wrongDetail = candidate()
        wrongDetail.previewDetail = MallWebDetail(number: "JD9999999999999", carrier: "京东物流", points: [MallWebPoint(date: eventTime, text: "本人已取件")])
        let wrongOrder = MallCandidate(trackingNumber: number, carrier: "京东物流", title: "", orderID: "999999999999", sourceURL: nil, previewDetail: candidate().previewDetail)
        var wrongURL = candidate(); wrongURL.sourceURL = "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=999999999999"
        var wrongCarrier = candidate(); wrongCarrier.previewDetail = MallWebDetail(number: number, carrier: "顺丰速运", points: [MallWebPoint(date: eventTime, text: "已签收")])
        for value in [wrongDetail, wrongOrder, wrongURL, wrongCarrier] {
            XCTAssertThrowsError(try app.applyMallPreview(id: old.id, candidate: value, expectedGeneration: generation))
            XCTAssertEqual(try shared.snapshot(), before)
        }
    }

    func testConfirmedPreviewImportRejectsCarrierConflictBeforeChangingAssociation() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = Shipment(trackingNumber: number, carrierName: "顺丰速运", carrierCode: "sf", note: "保留")
        try app.addThrowing(old)
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.importMall(candidate(), platform: "jd"))
        XCTAssertEqual(try shared.snapshot(), before)
    }

    func testHeldTrackingLeaseAndDeletedRecordRejectWithoutMutation() throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app), generation = MallSession.generation(for: .jd), before = try shared.snapshot()
        let lease = try shared.acquireTrackingQuery(id: old.id)
        XCTAssertThrowsError(try app.applyMallPreview(id: old.id, candidate: candidate(), expectedGeneration: generation)) {
            guard case PickupStorageError.queryInProgress = $0 else { return XCTFail("Expected lease conflict") }
        }
        XCTAssertEqual(try shared.snapshot(), before)
        lease.release()
        try app.deleteThrowing(id: old.id)
        let deleted = try shared.snapshot()
        XCTAssertThrowsError(try app.applyMallPreview(id: old.id, candidate: candidate(), expectedGeneration: generation))
        XCTAssertEqual(try shared.snapshot(), deleted)
    }

    func testBlankTraceIsNotAcceptedAsSuccessfulLogistics() throws {
        let value = MallCandidate(trackingNumber: number, carrier: "京东物流", title: "", orderID: order,
                                  previewDetail: MallWebDetail(number: number, carrier: "京东物流", points: [MallWebPoint(date: eventTime, text: " \n ")]))
        XCTAssertThrowsError(try value.jdPreviewResult()) { XCTAssertEqual($0 as? MallWebError, .noTrace) }
    }

    func testUnsafeOldOrderEntryRejectedBeforeCredentialsOrNetwork() async throws {
        for url in ["https://evil.invalid/order/deal_wuliu_jdm.shtml?dealId=\(order)",
                    "https://trade.m.jd.com/order/deal_wuliu_jdm.shtml?dealId=999999999999"] {
            do {
                _ = try await MallTrackingClient().query(platform: "jd", orderID: order, trackingNumber: number, sourceURL: url)
                XCTFail("Expected source identity rejection before any credential load")
            } catch { XCTAssertEqual(error as? MallWebError, .identityMismatch) }
        }
    }

    func testSavedSourceURLEntersExplicitOldOrderRefreshWithoutPaidFallback() async throws {
        let (root, shared, app) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try add(app), paid = TrackingRefreshTests.Client(), mall = Mall()
        _ = try await service(shared, paid: paid, mall: mall).refresh(id: old.id)
        XCTAssertEqual(mall.sourceURL, entry)
        XCTAssertEqual(mall.calls, 1); XCTAssertEqual(paid.calls, 0)
    }
}
