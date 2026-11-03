import XCTest
@testable import ParcelKeeper

final class DiagnosticChainTests: XCTestCase {
    private final class Transport: KDYZMTransport {
        var requests: [URLRequest] = []
        var response = Data()
        var status = 200
        var onSend: (() throws -> Void)?
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            try onSend?()
            return (response, status)
        }
    }
    private struct Fixture {
        let root: URL
        let store: SharedPickupStore
        let credential: KDYZMCredential
        let connection: KDYZMConnection
        let transport: Transport
        let client: KDYZMClient
        let log: DiagnosticLog
        var shipment: Shipment
        init(pending: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
            credential = .init(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
            transport = Transport()
            client = KDYZMClient(transport: transport)
            let keys = KDYZMNetworkTests.Keys(); keys.value = credential
            connection = KDYZMConnection(keys: keys, client: client)
            log = DiagnosticLog(directory: root.appendingPathComponent("logs"))
            var local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd", originPlatform: "jd", platformOrderID: "po")
            local.backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
            if pending { local.backendRefreshJobID = "j"; local.backendRefreshGeneration = credential.generation }
            shipment = local
            try store.transaction { data in
                data.shipments.append(local)
                data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "", source: "", shipmentID: local.id))
            }
        }
        func backend(budget: TimeInterval = 12) -> KDYZMRefreshService {
            KDYZMRefreshService(store: store, connection: connection, client: client, budget: budget, reloadWidgets: {}, diagnosticLog: log)
        }
        func outer() -> TrackingRefreshService {
            TrackingRefreshService(store: store, client: TrackingRefreshTests.Client(), reloadWidgets: {}, backendConnection: connection, backendClient: client, diagnosticLog: log)
        }
        func respond(state: String, accepted: Bool = false) {
            let job = "{\"id\":\"j\",\"accountId\":\"a\",\"orderId\":\"o\",\"state\":\"\(state)\"}"
            transport.response = Data((accepted ? "{\"accepted\":true,\"jobs\":[\(job)]}" : "{\"job\":\(job)}").utf8)
            transport.status = accepted ? 202 : 200
        }
    }
    func testNewQueuedBudgetIsWaitNotSaveAndRetainsJob() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.respond(state: "queued", accepted: true)
        do { _ = try await f.backend(budget: 1).refresh(before: f.shipment); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .queued) }
        XCTAssertEqual(try f.store.snapshot().shipments[0].backendRefreshJobID, "j")
        let text = f.log.snapshotForTesting().text
        XCTAssertTrue(text.contains("reason=queued stage=jobWait"))
        XCTAssertFalse(text.contains("reason=queued stage=save"))
        XCTAssertEqual(f.transport.requests.map(\.httpMethod), ["POST"])
    }
    func testNewJobCancellationAfterSaveIsWaitNotSave() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.respond(state: "queued", accepted: true)
        f.transport.onSend = { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { () -> Bool in
            do { _ = try await f.backend().refresh(before: f.shipment); return false }
            catch { return error is CancellationError }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try f.store.snapshot().shipments[0].backendRefreshJobID, "j")
        XCTAssertTrue(f.log.snapshotForTesting().text.contains("reason=cancelled stage=jobWait"))
    }
    func testJobGoneErrorAndCooldownCleanupFailurePreserveOriginal() async throws {
        for state in ["gone", "error", "cooldown"] {
            let f = try Fixture(pending: true); defer { try? FileManager.default.removeItem(at: f.root) }
            f.respond(state: state)
            if state == "gone" { f.transport.status = 404 }
            var lease: SharedPickupStore.TrackingQueryLease?
            f.transport.onSend = { lease = try f.store.acquireTrackingQuery(id: f.shipment.id) }
            defer { lease?.release() }
            let reason: DiagnosticReason = state == "gone" ? .jobGone : (state == "cooldown" ? .queued : .unavailable)
            do { _ = try await f.outer().refresh(id: f.shipment.id); XCTFail() }
            catch {
                let failure = try XCTUnwrap(error as? KDYZMTerminalResultError)
                XCTAssertEqual(failure.originalReason, reason)
                XCTAssertEqual(failure.originalStage, state == "gone" ? .jobResume : .jobWait)
                XCTAssertEqual(failure.cleanupReason, .busy)
            }
            let text = f.log.snapshotForTesting().text
            XCTAssertTrue(text.contains("reason=busy stage=cleanup"))
            XCTAssertTrue(text.components(separatedBy: "\n").contains { $0.contains("trackingFailed") && $0.contains("reason=\(reason.rawValue)") && !$0.contains("stage=preflight") })
            XCTAssertEqual(f.transport.requests.map(\.httpMethod), ["GET"])
            XCTAssertEqual(try f.store.snapshot().shipments[0].backendRefreshJobID, "j")
        }
    }
    func testCooldownSuccessfulCleanupStillCountsAsQueued() async throws {
        let f = try Fixture(pending: true); defer { try? FileManager.default.removeItem(at: f.root) }
        f.respond(state: "cooldown")
        let report = try await f.outer().refreshPending()
        XCTAssertEqual(report.queued.count, 1); XCTAssertEqual(report.failed, 0)
        XCTAssertNil(try f.store.snapshot().shipments[0].backendRefreshJobID)
        XCTAssertEqual(f.transport.requests.map(\.httpMethod), ["GET"])
    }
    func testPollingGoneCleanupFailureKeepsPollStageWithoutRepost() async throws {
        let f = try Fixture(pending: true); defer { try? FileManager.default.removeItem(at: f.root) }
        f.respond(state: "queued")
        var lease: SharedPickupStore.TrackingQueryLease?
        defer { lease?.release() }
        f.transport.onSend = {
            if f.transport.requests.count == 2 {
                f.transport.status = 404
                lease = try f.store.acquireTrackingQuery(id: f.shipment.id)
            }
        }
        do { _ = try await f.backend().refresh(before: f.shipment); XCTFail() }
        catch {
            let failure = try XCTUnwrap(error as? KDYZMTerminalResultError)
            XCTAssertEqual(failure.originalReason, .jobGone)
            XCTAssertEqual(failure.originalStage, .jobPoll)
            XCTAssertEqual(failure.cleanupReason, .busy)
        }
        XCTAssertEqual(f.transport.requests.map(\.httpMethod), ["GET", "GET"])
    }
    func testCooldownCleanupFailureIsExplicitBatchFailureNotSilentQueue() async throws {
        let f = try Fixture(pending: true); defer { try? FileManager.default.removeItem(at: f.root) }
        f.respond(state: "cooldown")
        var lease: SharedPickupStore.TrackingQueryLease?
        defer { lease?.release() }
        f.transport.onSend = { lease = try f.store.acquireTrackingQuery(id: f.shipment.id) }
        let report = try await f.outer().refreshPending()
        XCTAssertEqual(report.queued.count, 0); XCTAssertEqual(report.failed, 1)
        XCTAssertTrue(report.failures[0].reason.contains("任务清理未完成"))
        XCTAssertEqual(f.transport.requests.map(\.httpMethod), ["GET"])
    }
    func testOuterOrdinaryBackendFailureKeepsInnerStage() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.transport.status = 500
        do { _ = try await f.outer().refresh(id: f.shipment.id); XCTFail() } catch {}
        let text = f.log.snapshotForTesting().text
        XCTAssertTrue(text.components(separatedBy: "\n").contains { $0.contains("trackingFailed") && $0.contains("stage=jobCreate") })
        XCTAssertEqual(f.transport.requests.count, 1)
    }
    @MainActor func testSyncStaleMergerIsAssociationNotLease() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // Valid remote snapshot, but a bound order's platform identity changed.
        f.transport.response = Data(#"{"schemaVersion":1,"serverRevision":1,"accounts":[],"familyIds":["f"],"hiddenIds":[],"deletedIds":[],"orders":[{"id":"o","accountId":"a","platform":"pdd","platformOrderId":"po","familyId":"f"}],"shipments":[{"id":"s","orderId":"o","accountId":"a","familyId":"f","waybillNo":"JD123456789012","carrier":"京东物流","status":"transit"}]}"#.utf8)
        let store = ShipmentStore(storageProvider: { f.store })
        do { _ = try await store.syncKDYZM(connection: f.connection, client: f.client, diagnosticLog: f.log); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .stale) }
        let text = f.log.snapshotForTesting().text
        XCTAssertTrue(text.components(separatedBy: "\n").contains { $0.contains("syncFailed") && $0.contains("reason=identity stage=association") })
        XCTAssertFalse(text.contains("reason=identity stage=lease"))
        XCTAssertEqual(try f.store.snapshot().shipments[0], f.shipment)
    }

    func testFixedErrorClassification() {
        let cases: [(Error, DiagnosticReason)] = [
            (UAPIError.quota, .quota), (UAPIError.rateLimited(nil), .rateLimited),
            (UAPIError.cancelled, .cancelled), (UAPIError.noData, .noTrace),
            (TminiError.accounting, .accounting), (TminiError.configurationChanged, .configurationChanged),
            (KDYZMError.network, .network), (KDYZMError.rateLimited, .rateLimited),
            (KDYZMSyncFailure.decoding, .parse), (KDYZMSyncFailure.association, .association),
            (TaobaoTrackingError.authentication, .authentication), (MallWebError.verification, .verification),
            (TrackingTimeRejection(reason: .olderQuery), .olderQuery),
            (ShipmentShortcutError.olderUpdate, .olderEvent), (PickupStorageError.queryInProgress, .busy)
        ]
        for (error, expected) in cases { XCTAssertEqual(TrackingRefreshService.diagnosticReason(error), expected) }
    }
    func testCleanupDoesNotReplaceOriginalReasonOrClaimSuccess() {
        let error = KDYZMTerminalResultError(originalReason: .olderEvent, originalStage: .merge, cleanupReason: .storage)
        XCTAssertEqual(TrackingRefreshService.diagnosticReason(error), .olderEvent)
        XCTAssertEqual(error.originalStage, .merge)
        XCTAssertEqual(error.cleanupReason, .storage)
        XCTAssertFalse(error.localizedDescription.contains("任务已清除"))
    }
    func testTraceUsesOneRandomAliasAndDoesNotPersistCallerID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        let supplied = UUID()
        let trace = DiagnosticTrace(operation: supplied, log: log)
        trace.begin(.jobCreate); trace.begin(.snapshot); trace.fail(KDYZMError.network)
        let text = log.snapshotForTesting().text
        XCTAssertFalse(text.contains(supplied.uuidString))
        XCTAssertTrue(text.contains("reason=network stage=snapshot"))
        let aliases = text.components(separatedBy: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "operation=") else { return nil }
            return String(line[range.upperBound...].prefix(36))
        }
        XCTAssertEqual(aliases.count, 4)
        XCTAssertEqual(Set(aliases).count, 1)
    }
    func testOriginalSchemaWithoutStageIsReadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DiagnosticLog(directory: root)
        log.record(.trackingStarted)
        _ = log.snapshotForTesting()
        let url = root.appendingPathComponent("diagnostics.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index].removeValue(forKey: "stage") }
        archive["entries"] = entries
        try JSONSerialization.data(withJSONObject: archive).write(to: url)
        XCTAssertEqual(DiagnosticLog(directory: root).snapshotForTesting().status, .ready)
    }
}
