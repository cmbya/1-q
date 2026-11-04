import XCTest
@testable import ParcelKeeper

final class MallRoutingTests: XCTestCase {
    final class Mall: MallTrackingQuerying {
        var calls: [(String, String, String)] = []
        var failure: Error?
        var onQuery: (() throws -> Void)?
        var wrongNumber = false
        func query(platform: String, orderID: String, trackingNumber: String) async throws -> UAPITrackingResult {
            calls.append((platform, orderID, trackingNumber))
            try onQuery?()
            if let failure { throw failure }
            return UAPITrackingResult(trackingNumber: wrongNumber ? "SF9999999999999" : trackingNumber, carrierName: "", carrierCode: "", status: .delivered, logisticsInfo: "本人签收", logisticsTime: nil, queryInfo: "平台轨迹", queriedAt: Date())
        }
    }
    var root: URL!
    var storage: SharedPickupStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func add(_ platform: String?, order: String? = nil, channel: String? = nil, index: Int = 0) throws -> Shipment {
        let item = Shipment(trackingNumber: "YT12345678901\(index)", carrierName: "圆通", carrierCode: "yto", note: "用户备注", pickupCode: "取码\(index)", reminderDate: Date(timeIntervalSince1970: 2000), logisticsInfo: "旧轨迹", queryInfo: "旧详情", originPlatform: platform, refreshChannel: channel, platformOrderID: order)
        try storage.transaction { data in
            data.shipments.append(item)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: item.pickupCode, source: item.note, shipmentID: item.id))
        }
        return item
    }
    private func order(_ platform: String) -> String { "261102-123456789012345" }
    func testOldBackupDecodesAndPlatformOrderRoundTripsIndependentlyOfTaobao() throws {
        let item = try add(nil)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: storage.exportBackup()) as? [String: Any])
        var rows = try XCTUnwrap(object["shipments"] as? [[String: Any]])
        rows[0].removeValue(forKey: "platformOrderID"); object["shipments"] = rows
        let old = try JSONDecoder().decode(PickupDataset.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.shipments[0].platformOrderID)
        XCTAssertEqual(old.shipments[0].id, item.id)
        for platform in ["pdd"] {
            var bound = item
            bound.originPlatform = platform; bound.platformOrderID = order(platform)
            bound.taobaoOrderID = "987654321"
            XCTAssertEqual(try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(bound)), bound)
        }
    }
    func testPDDDispatchWithoutPhoneOrUAPIFallbackInAutomaticAndPlatformOnly() async throws {
        for (index, pair) in [("pdd", TrackingRefreshMode.automatic), ("pdd", .platformOnly)].enumerated() {
            let (platform, mode) = pair
            let item = try add(platform, order: order(platform), index: index)
            let mall = Mall(); let uapi = TrackingRefreshTests.Client()
            let service = TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall)
            _ = try await service.refresh(id: item.id, phone: "invalid-phone", mode: mode)
            XCTAssertEqual(mall.calls.count, 1)
            XCTAssertEqual(mall.calls.first?.0, platform)
            XCTAssertEqual(mall.calls.first?.1, order(platform))
            XCTAssertEqual(uapi.calls, 0)
            let saved = try XCTUnwrap(storage.snapshot().shipments.first { $0.id == item.id })
            XCTAssertEqual(saved.logisticsSource, platform)
            XCTAssertEqual(saved.note, item.note); XCTAssertEqual(saved.pickupCode, item.pickupCode)
            XCTAssertEqual(saved.reminderDate, item.reminderDate)
        }
    }

    func testExplicitUAPIOverrideAndModeRemainAvailable() async throws {
        for (index, mode) in [TrackingRefreshMode.automatic, .uapi].enumerated() {
            let item = try add("unsupported_market", channel: index == 0 ? "uapi" : nil, index: index)
            let mall = Mall(); let uapi = TrackingRefreshTests.Client()
            uapi.result = UAPITrackingResult(trackingNumber: item.trackingNumber, carrierName: "", carrierCode: "", status: nil, logisticsInfo: "新轨迹", logisticsTime: nil, queryInfo: "新详情", queriedAt: Date())
            _ = try await TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall).refresh(id: item.id, mode: mode)
            XCTAssertEqual(uapi.calls, 1); XCTAssertTrue(mall.calls.isEmpty)
        }
    }
    func testPlatformOnlyIgnoresUAPIOverride() async throws {
        let item = try add("pdd", order: order("pdd"), channel: "uapi")
        let mall = Mall(); let uapi = TrackingRefreshTests.Client()
        _ = try await TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall).refresh(id: item.id, mode: .platformOnly)
        XCTAssertEqual(mall.calls.count, 1); XCTAssertEqual(uapi.calls, 0)
    }
    func testUnknownPlatformMissingAndMalformedBindingNeverChargeOrDispatchMall() async throws {
        for (index, pair) in [("douyin", "123456"), ("pdd", "123456"), ("pdd", "261102-123456\n")].enumerated() {
            let item = try add(pair.0, order: pair.1, index: index)
            let mall = Mall(); let uapi = TrackingRefreshTests.Client()
            do { _ = try await TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall).refresh(id: item.id); XCTFail() } catch {}
            XCTAssertEqual(uapi.calls, 0); XCTAssertTrue(mall.calls.isEmpty)
        }
    }
    func testAllMallFailuresPreserveBusinessDataAndSafePlatformStage() async throws {
        let errors: [Error] = [MallWebError.authentication, MallWebError.verification, MallWebError.unsupported, MallWebError.identityMismatch, MallWebError.noTrace, MallWebError.timeout, NSError(domain: "secret-cookie", code: 1)]
        for (index, error) in errors.enumerated() {
            let item = try add("pdd", order: order("pdd"), index: index)
            let mall = Mall(); mall.failure = error
            let uapi = TrackingRefreshTests.Client()
            do { _ = try await TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall).refresh(id: item.id); XCTFail() } catch {}
            var saved = try XCTUnwrap(storage.snapshot().shipments.first { $0.id == item.id })
            let reason = try XCTUnwrap(saved.lastRefreshError)
            XCTAssertTrue(reason.contains("拼多多")); XCTAssertTrue(reason.contains("刷新"))
            XCTAssertFalse(reason.contains("secret-cookie"))
            saved.lastRefreshError = nil
            XCTAssertEqual(saved, item); XCTAssertEqual(uapi.calls, 0)
        }
    }
    func testIdentityMismatchAndConcurrentRebindCannotOverwrite() async throws {
        let item = try add("pdd", order: order("pdd"))
        let mall = Mall(); let uapi = TrackingRefreshTests.Client()
        mall.wrongNumber = true
        let service = TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall)
        do { _ = try await service.refresh(id: item.id); XCTFail() } catch { XCTAssertEqual(error as? MallWebError, .identityMismatch) }
        mall.wrongNumber = false
        mall.onQuery = { try self.storage.transaction { $0.shipments[0].platformOrderID = "261103-999999999999" } }
        do { _ = try await service.refresh(id: item.id); XCTFail() } catch { guard case PickupStorageError.stalePreview = error else { return XCTFail("Expected stalePreview") } }
        XCTAssertEqual(try storage.snapshot().shipments[0].logisticsInfo, "旧轨迹")
        XCTAssertEqual(uapi.calls, 0)
    }
    func testPlatformBlockingIsScopedAndReportCountsSources() async throws {
        for (index, platform) in ["pdd", "pdd", "pdd"].enumerated() {
            let item = try add(platform, order: order(platform), index: index)
            try storage.transaction { data in
                let i = data.shipments.firstIndex { $0.id == item.id }!
                data.shipments[i].lastQueryAttemptAt = Date(timeIntervalSince1970: Double(index))
            }
        }
        let mall = Mall(); mall.failure = MallWebError.authentication
        let uapi = TrackingRefreshTests.Client()
        let report = try await TrackingRefreshService(store: storage, client: uapi, reloadWidgets: {}, mallClient: mall).refreshPending()
        XCTAssertEqual(mall.calls.map { $0.0 }, ["pdd"])
        XCTAssertEqual(report.pddCount, 1)
        XCTAssertEqual(report.taobaoCount, 0); XCTAssertEqual(report.uapiCount, 0)
        XCTAssertEqual(report.failed, 1); XCTAssertEqual(report.skipped, 2)
    }
    func testPlatformAndChannelChangesRejectStaleResponseAndPreserveCompletion() async throws {
        for (index, changeChannel) in [false, true].enumerated() {
            let item = try add("pdd", order: order("pdd"), index: index)
            let mall = Mall()
            mall.onQuery = {
                try self.storage.transaction { data in
                    let i = data.shipments.firstIndex { $0.id == item.id }!
                    if changeChannel { data.shipments[i].refreshChannel = "uapi" }
                    else { data.shipments[i].originPlatform = "unsupported_market" }
                }
            }
            do { _ = try await TrackingRefreshService(store: storage, client: TrackingRefreshTests.Client(), reloadWidgets: {}, mallClient: mall).refresh(id: item.id); XCTFail() }
            catch { guard case PickupStorageError.stalePreview = error else { return XCTFail("Expected stalePreview") } }
            let saved = try XCTUnwrap(storage.snapshot().shipments.first { $0.id == item.id })
            XCTAssertEqual(saved.logisticsInfo, "旧轨迹")
            XCTAssertNil(saved.lastRefreshError)
            XCTAssertFalse(try XCTUnwrap(storage.snapshot().records.first { $0.shipmentID == item.id }).isCompleted)
        }
    }
    func testMallQueryLeaseNoDatasetLockAndCancellationReleasesLease() async throws {
        let item = try add("pdd", order: order("pdd"))
        let mall = Mall()
        mall.onQuery = {
            _ = try self.storage.snapshot()
            XCTAssertThrowsError(try self.storage.acquireTrackingQuery(id: item.id))
        }
        mall.failure = CancellationError()
        let service = TrackingRefreshService(store: storage, client: TrackingRefreshTests.Client(), reloadWidgets: {}, mallClient: mall)
        do { _ = try await service.refresh(id: item.id); XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try storage.snapshot().shipments[0], item)
        mall.failure = nil
        _ = try await service.refresh(id: item.id)
        XCTAssertEqual(mall.calls.count, 2)
    }
    func testOlderMallTraceReplacesPreviousResult() async throws {
        let item = try add("pdd", order: order("pdd"))
        try storage.transaction {
            $0.shipments[0].logisticsTime = Date(timeIntervalSince1970: 1000)
            $0.shipments[0].lastQueriedAt = .distantFuture
        }
        let mall = Mall()
        _ = try await TrackingRefreshService(store: storage, client: TrackingRefreshTests.Client(), reloadWidgets: {}, mallClient: mall).refresh(id: item.id)
        let saved = try XCTUnwrap(storage.snapshot().shipments.first)
        XCTAssertNotEqual(saved.logisticsInfo, "旧轨迹")
        // A valid response without an event timestamp also replaces the saved time.
        XCTAssertNil(saved.logisticsTime)
        XCTAssertLessThan(try XCTUnwrap(saved.lastQueriedAt), Date.distantFuture)
        XCTAssertEqual(saved.logisticsSource, "pdd")
    }
    @MainActor func testImportAmbiguousHistoryRejectsWithoutMutation() throws {
        let item = try add(nil)
        try storage.transaction { data in
            var duplicate = item; duplicate.id = UUID()
            duplicate.pickupCode = "另一取码"
            data.shipments.append(duplicate)
            data.records.append(PickupRecord(groupID: data.records[0].groupID, code: duplicate.pickupCode, source: duplicate.note, shipmentID: duplicate.id))
        }
        let before = try storage.exportBackup()
        let store = ShipmentStore(storageProvider: { self.storage })
        XCTAssertThrowsError(try store.importMall(MallCandidate(trackingNumber: item.trackingNumber, carrier: "", title: "", orderID: order("pdd")), platform: "pdd")) {
            XCTAssertEqual($0 as? ShipmentShortcutError, .ambiguous)
        }
        XCTAssertEqual(try storage.exportBackup(), before)
    }
    @MainActor func testImportBindsUniqueRecordWithoutChangingUserFieldsOrOverride() throws {
        for (index, platform) in ["pdd"].enumerated() {
            let item = try add(nil, channel: "uapi", index: index)
            let records = try storage.snapshot().records
            let store = ShipmentStore(storageProvider: { self.storage })
            let id = try store.importMall(MallCandidate(trackingNumber: item.trackingNumber, carrier: "顺丰", title: "商城标题", orderID: order(platform)), platform: platform)
            XCTAssertEqual(id, item.id)
            var saved = try XCTUnwrap(storage.snapshot().shipments.first { $0.id == id })
            XCTAssertEqual(saved.originPlatform, platform); XCTAssertEqual(saved.platformOrderID, order(platform))
            saved.originPlatform = item.originPlatform; saved.platformOrderID = item.platformOrderID
            XCTAssertEqual(saved, item)
            XCTAssertEqual(try storage.snapshot().records, records)
        }
    }
    @MainActor func testImportRejectsConflictInvalidIDsAndLeaseWithoutMutation() throws {
        let item = try add("taobao")
        let store = ShipmentStore(storageProvider: { self.storage })
        let before = try storage.exportBackup()
        let candidate = MallCandidate(trackingNumber: item.trackingNumber, carrier: "", title: "", orderID: order("pdd"))
        XCTAssertThrowsError(try store.importMall(candidate, platform: "pdd"))
        XCTAssertThrowsError(try store.importMall(candidate, platform: "douyin"))
        for (platform, invalid) in [("pdd", "123456"), ("pdd", " 261102-123456")] {
            XCTAssertThrowsError(try store.importMall(MallCandidate(trackingNumber: item.trackingNumber, carrier: "", title: "", orderID: invalid), platform: platform))
        }
        let lease = try storage.acquireTrackingQuery(id: item.id)
        defer { lease.release() }
        XCTAssertThrowsError(try store.importMall(candidate, platform: "pdd")) { guard case PickupStorageError.queryInProgress = $0 else { return XCTFail("Expected queryInProgress") } }
        XCTAssertEqual(try storage.exportBackup(), before)
    }
    @MainActor func testImportNewMallShipmentAndConflictingOrder() throws {
        let store = ShipmentStore(storageProvider: { self.storage })
        let candidate = MallCandidate(trackingNumber: "SF1234567890123", carrier: "顺丰", title: "新订单", orderID: order("pdd"))
        let id = try store.importMall(candidate, platform: "pdd")
        XCTAssertEqual(try store.importMall(candidate, platform: "pdd"), id)
        let saved = try XCTUnwrap(storage.snapshot().shipments.first)
        XCTAssertEqual(saved.platformOrderID, order("pdd")); XCTAssertNil(saved.taobaoOrderID)
        XCTAssertEqual(saved.note, "新订单")
        XCTAssertThrowsError(try store.importMall(MallCandidate(trackingNumber: candidate.trackingNumber, carrier: "", title: "", orderID: "261103-999999999999999"), platform: "pdd"))
        XCTAssertEqual(try storage.snapshot().records.filter { $0.shipmentID == id }.count, 1)
    }
}

