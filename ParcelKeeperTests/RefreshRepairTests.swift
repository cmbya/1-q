import XCTest
@testable import ParcelKeeper

/// All credentials, replies and transports are synthetic; never calls a paid API.
final class RefreshRepairTests: XCTestCase {
    final class Tmini: TminiTrackingQuerying {
        let settings: TminiSettingsService
        var result: UAPITrackingResult
        init(settings: TminiSettingsService, result: UAPITrackingResult) { self.settings = settings; self.result = result }
        func configurationToken() throws -> TminiConfiguration { try settings.configurationToken() }
        func validateConfiguration(_ token: TminiConfiguration) throws { try settings.validateConfiguration(token) }
        func query(trackingNumber: String) async throws -> UAPITrackingResult { result }
    }
    var root: URL!
    var store: SharedPickupStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult func add(_ platform: String? = nil, index: Int = 0) throws -> Shipment {
        let item = Shipment(trackingNumber: "YT12345678901\(index)", carrierName: "圆通", carrierCode: "yto", note: "用户备注", pickupCode: "码\(index)", reminderDate: Date(timeIntervalSince1970: 1234), logisticsInfo: "原节点", queryInfo: "原历史", originPlatform: platform, platformOrderID: platform == "pdd" ? "261102-123456789012345" : nil)
        try store.transaction { data in
            var scheduled = item
            scheduled.lastQueryAttemptAt = Date(timeIntervalSince1970: Double(index))
            data.shipments.append(scheduled)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: item.pickupCode, source: item.note, isCompleted: true, shipmentID: item.id))
        }
        return item
    }


    func testMallClearOrReplacementWhileQueryRunsRejectsAllLateWrites() async throws {
        let keys = UAPITrackingClientTests.Keys()
        for platform in [MallPlatform.pdd] {
            for replace in [false, true] {
                try store.transaction { $0.shipments.removeAll(); $0.records.removeAll() }
                let item = try add(platform.rawValue)
                let before = try store.exportBackup()
                let session = MallSession(platform: platform, keys: keys)
                let mall = MallRoutingTests.Mall()
                mall.onQuery = {
                    _ = try self.store.snapshot() // no data/session lock across await
                    if replace {
                        let names = ["PDDAccessToken", "pdd_user_id"]
                        let cookies = names.map { TaobaoTrialCookie(name: $0, value: "synthetic", domain: ".yangkeduo.com", path: "/", secure: true, expires: nil) }
                        try session.save(cookies)
                    } else { try session.clear() }
                }
                do {
                    _ = try await TrackingRefreshService(store: store, client: TrackingRefreshTests.Client(), reloadWidgets: {}, mallClient: mall).refresh(id: item.id)
                    XCTFail("Retired session must reject late result")
                } catch {}
                XCTAssertEqual(try store.exportBackup(), before) // even diagnostics cannot use old session
                let lease = try store.acquireTrackingQuery(id: item.id); lease.release()
            }
        }
    }
    func testRetiredMallFailureCannotPersistDiagnostic() async throws {
        for platform in [MallPlatform.pdd] {
            try store.transaction { $0.shipments.removeAll(); $0.records.removeAll() }
            let item = try add(platform.rawValue)
            let before = try store.exportBackup()
            let mall = MallRoutingTests.Mall()
            mall.failure = MallWebError.authentication
            mall.onQuery = { try MallSession(platform: platform, keys: UAPITrackingClientTests.Keys()).clear() }
            do {
                _ = try await TrackingRefreshService(store: store, client: TrackingRefreshTests.Client(), reloadWidgets: {}, mallClient: mall).refresh(id: item.id)
                XCTFail()
            } catch { XCTAssertEqual(error as? MallWebError, .authentication) }
            XCTAssertEqual(try store.exportBackup(), before)
        }
    }
    func testUAPIConfigChangedAfterClientReturnBeforeCommitCannotWrite() async throws {
        for replace in [false, true] {
            try store.transaction { $0.shipments.removeAll(); $0.records.removeAll() }
            let item = try add()
            let suite = "RefreshRepair." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = UAPISettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
            try settings.saveKey("synthetic-key"); try settings.setEnabled(true, privacyConfirmed: true)
            let network = UAPITrackingClientTests.Network()
            network.body = try JSONSerialization.data(withJSONObject: ["tracking_number": item.trackingNumber, "tracks": [["time": "2026-10-30 10:00", "context": "运输中"]]])
            let client = UAPITrackingClient(settings: settings, network: network)
            let before = try store.exportBackup()
            do {
                _ = try await TrackingRefreshService(store: store, client: client, reloadWidgets: {}).refresh(id: item.id, cacheFeedback: { _ in
                    if replace { try! settings.saveKey("replacement-key") }
                    else { try! settings.setEnabled(false) }
                })
                XCTFail("Configuration changed between return and write")
            } catch { XCTAssertEqual(error as? UAPIError, .configurationChanged) }
            XCTAssertEqual(try store.exportBackup(), before)
            XCTAssertEqual(network.requests.count, 1)
        }
    }
    func testPreflightFailureCountsRouteAttemptsWithoutClaimingNetworkOrBilling() async throws {
        let item = try add("pdd")
        try store.transaction { $0.shipments[0].platformOrderID = nil }
        let mall = MallRoutingTests.Mall(), paid = TrackingRefreshTests.Client()
        let report = try await TrackingRefreshService(store: store, client: paid, reloadWidgets: {}, mallClient: mall).refreshPending()
        XCTAssertEqual(report.pddCount, 1); XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(mall.calls.isEmpty); XCTAssertEqual(paid.calls, 0)
        XCTAssertTrue(report.message.contains("按渠道尝试票数"))
        XCTAssertTrue(report.message.contains("不代表实际网络请求或收费次数"))
        XCTAssertEqual(try store.snapshot().shipments.first?.id, item.id)
    }
    func testBackendPaidBackendHistoryKeepsEveryLineOnceWithoutRecursiveGrowth() async throws {
        let item = try add()
        let record = try XCTUnwrap(store.snapshot().records.first)
        let remote = KDYZMRemoteShipment(id: "s", orderId: "o", accountId: "a", waybillNo: item.trackingNumber, carrier: "圆通", status: "transit", logisticsEvents: [.init(time: 100_000, timeText: "", description: "后台节点", location: "")], logisticsState: "ok", logisticsUpdatedAt: 100_000)
        try store.transaction { _ = try KDYZMMerger.update(remote, local: &$0.shipments[0]) }
        let paid = TrackingRefreshTests.Client()
        var service = TrackingRefreshService(store: store, client: paid, reloadWidgets: {})
        paid.result = UAPITrackingResult(trackingNumber: item.trackingNumber, carrierName: "", carrierCode: "", status: .inTransit, logisticsInfo: "UAPI节点", logisticsTime: Date(timeIntervalSince1970: 50), queryInfo: "UAPI完整历史\n中间节点", queriedAt: Date(timeIntervalSince1970: 50))
        _ = try await service.refresh(id: item.id, mode: .uapi)
        let suite = "HistoryRepair." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        try settings.saveKey("synthetic-tmini"); try settings.setEnabled(true, privacyConfirmed: true)
        let tmini = Tmini(settings: settings, result: UAPITrackingResult(trackingNumber: item.trackingNumber, carrierName: "", carrierCode: "", status: .inTransit, logisticsInfo: "Tmini节点", logisticsTime: nil, queryInfo: "Tmini完整历史\n中间节点", queriedAt: Date(timeIntervalSince1970: 25)))
        service.tminiClient = tmini
        _ = try await service.refresh(id: item.id, mode: .tmini)
        try store.transaction { _ = try KDYZMMerger.update(remote, local: &$0.shipments[0]) }
        let stable = try XCTUnwrap(store.snapshot().shipments.first?.queryInfo)
        for expected in ["原历史", "UAPI完整历史", "Tmini完整历史", "中间节点"] {
            XCTAssertEqual(stable.components(separatedBy: "\n").filter { $0 == expected }.count, 1)
        }
        for _ in 0..<10 { try store.transaction { _ = try KDYZMMerger.update(remote, local: &$0.shipments[0]) } }
        let saved = try XCTUnwrap(store.snapshot().shipments.first)
        XCTAssertEqual(saved.queryInfo, stable)
        XCTAssertEqual(saved.logisticsInfo, "后台节点")
        XCTAssertEqual(saved.id, item.id); XCTAssertEqual(saved.note, item.note)
        XCTAssertEqual(saved.reminderDate, item.reminderDate)
        XCTAssertTrue(try XCTUnwrap(store.snapshot().records.first).isCompleted)
        XCTAssertEqual(try store.snapshot().records.first?.groupID, record.groupID)
    }
}

