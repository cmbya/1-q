import XCTest
import WebKit
@testable import ParcelKeeper

final class AuditMediumUITests: XCTestCase {
    private final class Keys: AIKeyStore {
        var value: String?
        func read() throws -> String? { value }
        func save(_ key: String) throws { value = key }
        func delete() throws { value = nil }
        private var endpoints: [String: String] = [:]
        func read(endpoint: String) throws -> String? { endpoints[endpoint] }
        func save(_ key: String, endpoint: String) throws { endpoints[endpoint] = key }
        func delete(endpoint: String) throws { endpoints.removeValue(forKey: endpoint) }
    }
    private func cookie(_ name: String, expires: Date? = nil, domain: String = ".yangkeduo.com", path: String = "/") -> TaobaoTrialCookie {
        .init(name: name, value: "fixture", domain: domain, path: path, secure: true, expires: expires)
    }
    func testExpiredAnalyticsDoesNotInvalidateLiveCredentials() throws {
        let keys = Keys()
        let session = MallSession(platform: .pdd, keys: keys)
        let live = [cookie("PDDAccessToken"), cookie("pdd_user_id")]
        keys.value = String(decoding: try JSONEncoder().encode(live + [cookie("analytics", expires: .distantPast)]), as: UTF8.self)
        XCTAssertEqual(try session.load().map(\.name), live.map(\.name))
        try session.save(live)
        XCTAssertEqual(try session.load().count, 2)
    }
    func testExpiredCredentialsAndMalformedExpiredCookiesFailClosed() throws {
        let keys = Keys()
        let session = MallSession(platform: .pdd, keys: keys)
        for cookies in [
            [cookie("PDDAccessToken", expires: .distantPast), cookie("pdd_user_id")],
            [cookie("PDDAccessToken"), cookie("pdd_user_id"), cookie("analytics", expires: .distantPast, domain: "evil.test")],
            [cookie("PDDAccessToken"), cookie("pdd_user_id"), cookie("analytics", expires: .distantPast, domain: "yangkeduo.com/evil")],
            [cookie("PDDAccessToken", path: "/other"), cookie("pdd_user_id")]
        ] {
            keys.value = String(decoding: try JSONEncoder().encode(cookies), as: UTF8.self)
            XCTAssertThrowsError(try session.load())
        }
        XCTAssertThrowsError(try session.save([cookie("analytics", expires: .distantPast)]))
        for field in 0..<3 {
            let malformed = TaobaoTrialCookie(name: field == 0 ? "analytics\u{0001}" : "analytics",
                value: field == 1 ? "fixture\u{007F}" : "fixture", domain: ".yangkeduo.com",
                path: field == 2 ? "/\u{0000}" : "/", secure: true, expires: .distantPast)
            keys.value = String(decoding: try JSONEncoder().encode([cookie("PDDAccessToken"), cookie("pdd_user_id"), malformed]), as: UTF8.self)
            XCTAssertThrowsError(try session.load())
        }
    }
    func testOrderDateOwnsOnlyItsTimestampContinuation() throws {
        let journey = "出发日期：2027-01-01\n车次：G123\n出发站：北京南\n发车时间：09:00\n到达站：上海虹桥"
        for label in ["下单时间", "订单日期", "支付时间", "出票日期", "购票时间"] {
            for prefix in ["", "\n", "\r\n"] {
                for separator in ["\n", "\r\n", " "] {
                    let raw = label + "：" + prefix + "2026-10-31" + separator + "08:12:34\n" + journey
                    let evidence = TrainTicketRecognition.travelEvidence(raw)
                    XCTAssertFalse(evidence.contains("2026-10-31"), raw)
                    XCTAssertFalse(evidence.contains("08:12"), raw)
                    XCTAssertTrue(evidence.contains("2027-01-01"), raw)
                    XCTAssertTrue(evidence.contains("09:00"), raw)
                    XCTAssertEqual(try TrainTicketRecognition.parse(raw).departureDate, "2027-01-01")
                }
            }
        }
        for continuation in ["出发时间：08:12", "北京南 08:12", "车次：G123\n08:12"] {
            XCTAssertTrue(TrainTicketRecognition.travelEvidence("下单时间：2026-10-31\n" + continuation).contains("08:12"))
        }
        XCTAssertEqual(TrainTicketRecognition.travelEvidence("2027-01-01\n08:12"), "2027-01-01\n08:12")
    }
    @MainActor func testStopBeforeCookieInitializationPreventsLoad() async {
        let browser = TaobaoTrialBrowser(cookies: [cookie("cookie2", domain: ".taobao.com")])
        browser.stop()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(browser.web.url)
        XCTAssertFalse(browser.web.isLoading)
        browser.stop() // idempotent teardown
    }
    @MainActor func testReconnectAwaitsReconciliationAndReturnsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, containerURL: root)
        let store = ShipmentStore(storageProvider: { storage })
        var calls = 0
        store.reminderReconciler = { desired in
            calls += 1
            XCTAssertEqual(desired, [])
            XCTAssertTrue(store.reminderOperationInProgress)
            return ["fixture reconciliation failure"]
        }
        let warnings = try await store.reconnectSharedStorage(storageProvider: { storage })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(warnings, ["fixture reconciliation failure"])
        XCTAssertEqual(store.lastErrorMessage, warnings.first)
        XCTAssertFalse(store.reminderOperationInProgress)
        XCTAssertTrue(store.beginReminderOperation())
        do {
            _ = try await store.reconnectSharedStorage(storageProvider: { XCTFail("must reject busy reconnect before opening storage"); return storage })
            XCTFail("expected busy failure")
        } catch { }
        store.endReminderOperation()
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testReconnectRejectsReadOnlyBeforeReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writable = try SharedPickupStore(appGroupID: nil, containerURL: root)
        let historical = try SharedPickupStore(appGroupID: nil, containerURL: root, readOnly: true)
        let store = ShipmentStore(storageProvider: { writable })
        store.reminderReconciler = { _ in XCTFail("must not reconcile historical data"); return [] }
        do {
            _ = try await store.reconnectSharedStorage(storageProvider: { historical })
            XCTFail("expected read-only rejection")
        } catch { }
        XCTAssertFalse(store.isHistoricalSnapshot)
        XCTAssertFalse(store.reminderOperationInProgress)
    }
}
