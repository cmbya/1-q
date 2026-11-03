import XCTest
@testable import ParcelKeeper

final class PaidTrackingCacheTests: XCTestCase {
    var directory: URL!
    var cache: PaidTrackingCache!
    var secrets: [String: UAPITrackingClientTests.Keys] = [:]
    let number = "YT1234567890123"
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = PaidTrackingCache(directory: directory, phoneKeys: { name in
            if let keys = self.secrets[name] { return keys }
            let keys = UAPITrackingClientTests.Keys(); self.secrets[name] = keys; return keys
        })
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        secrets = [:]
        super.tearDown()
    }
    func result(_ status: ShipmentStatus? = .inTransit, at: Date? = nil) -> UAPITrackingResult {
        UAPITrackingResult(trackingNumber: number, carrierName: "圆通", carrierCode: "yuantong", status: status, logisticsInfo: "运输中", logisticsTime: now.addingTimeInterval(-100), queryInfo: "完整历史\n已揽收\n运输中", queriedAt: at ?? now)
    }
    func identity(_ channel: String, generation: String = "generation-A", carrier: String = "", phone: String? = nil) throws -> PaidTrackingCache.Identity {
        try cache.identity(channel: channel, number: number, carrier: carrier, generation: generation, phone: phone)
    }
    func testBothChannelsFullResultAndOriginalTimestamp() throws {
        for channel in ["uapi", "tmini"] {
            let key = try identity(channel)
            try cache.store(result(), identity: key, startedAt: now.addingTimeInterval(-1), now: now)
            let hit = try XCTUnwrap(cache.lookup(key, now: now.addingTimeInterval(299)))
            XCTAssertTrue(hit.isCached)
            XCTAssertEqual(hit.queriedAt, now)
            XCTAssertEqual(hit.queryInfo, result().queryInfo)
            XCTAssertEqual(hit.carrierCode, result().carrierCode)
            XCTAssertEqual(hit.logisticsTime, result().logisticsTime)
        }
    }
    func testExactTTLFutureAndRollbackBoundaries() {
        let cases: [(ShipmentStatus?, Double)] = [(.inTransit, 7200), (.outForDelivery, 1800), (.readyForPickup, 21600), (.delivered, 604800), (.exception, 7200), (nil, 7200)]
        for (state, ttl) in cases {
            XCTAssertTrue(PaidTrackingCache.isFresh(result(state), now: now))
            XCTAssertTrue(PaidTrackingCache.isFresh(result(state), now: now.addingTimeInterval(ttl - 0.001)))
            XCTAssertFalse(PaidTrackingCache.isFresh(result(state), now: now.addingTimeInterval(ttl)))
            XCTAssertFalse(PaidTrackingCache.isFresh(result(state), now: now.addingTimeInterval(-0.001)))
        }
    }
    func testChannelCarrierGenerationAndFullNumberIsolation() throws {
        let key = try identity("tmini")
        try cache.store(result(), identity: key, startedAt: now, now: now)
        XCTAssertNil(try cache.lookup(identity("uapi"), now: now))
        XCTAssertNil(try cache.lookup(identity("tmini", generation: "B"), now: now))
        XCTAssertNil(try cache.lookup(identity("tmini", carrier: "other"), now: now))
        let other = try cache.identity(channel: "tmini", number: number + "9", generation: "generation-A")
        XCTAssertNil(try cache.lookup(other, now: now))
    }
    func testPhoneRotationNoTailOrHashInJSONAndLateIdentityRejected() throws {
        let a = try identity("uapi", phone: "9276")
        try cache.store(result(), identity: a, startedAt: now, now: now)
        let b = try identity("uapi", phone: "8351")
        XCTAssertNotEqual(a.phoneToken, b.phoneToken)
        XCTAssertThrowsError(try cache.lookup(a, now: now))
        XCTAssertThrowsError(try cache.store(result(), identity: a, startedAt: now, now: now))
        let again = try identity("uapi", phone: "9276")
        XCTAssertNotEqual(a.phoneToken, again.phoneToken)
        XCTAssertNil(try cache.lookup(again, now: now))
        let json = try String(contentsOf: directory.appendingPathComponent("success-v1.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("9276")); XCTAssertFalse(json.contains("8351"))
        XCTAssertFalse(json.contains("synthetic-key"))
    }
    func testOlderRequestCannotOverwriteNewerEntryAndCorruptionFailsClosed() throws {
        let key = try identity("tmini")
        try cache.store(result(), identity: key, startedAt: now, now: now)
        try cache.store(result(at: now.addingTimeInterval(-1)), identity: key, startedAt: now.addingTimeInterval(-2), now: now)
        XCTAssertEqual(try cache.lookup(key, now: now)?.queriedAt, now)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("success-v1.json"))
        XCTAssertThrowsError(try cache.lookup(key, now: now))
    }
    func testTminiHitNeverDispatchesOrAddsFourPointsAndDisabledDoesNotRead() async throws {
        let suite = "PaidTmini." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        try settings.saveKey("synthetic-key"); try settings.setEnabled(true, privacyConfirmed: true)
        let network = UAPITrackingClientTests.Network()
        network.body = try JSONSerialization.data(withJSONObject: ["code": "0000000000", "data": ["serviceCode": 0, "packageInfoList": [["trackingNo": number, "state": "TRANSPORT", "trackingDetails": [["time": "20261102100000", "context": "运输中"]]]]]])
        let usage = TminiUsageStore(directory: directory)
        let client = TminiTrackingClient(settings: settings, network: network, usage: usage, cache: cache)
        let first = try await client.query(trackingNumber: number)
        let second = try await client.query(trackingNumber: number)
        XCTAssertFalse(first.isCached); XCTAssertTrue(second.isCached)
        XCTAssertEqual(first.queriedAt, second.queriedAt)
        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(try usage.summary().points, 4)
        let forced = TminiTrackingClient(settings: settings, network: network, usage: usage, cache: cache, ignoreCache: true)
        let forcedResult = try await forced.query(trackingNumber: number)
        XCTAssertFalse(forcedResult.isCached)
        XCTAssertEqual(network.requests.count, 2)
        XCTAssertEqual(try usage.summary().points, 8)
        try settings.setEnabled(false)
        do { _ = try await forced.query(trackingNumber: number); XCTFail("Disabled must fail") } catch {}
        XCTAssertEqual(network.requests.count, 2)
    }
    func testUAPIHitRefreshTrueDoesNotDispatchOrUpdateBillingAndFailuresNotCached() async throws {
        let suite = "PaidUAPI." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = UAPISettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        try settings.saveKey("synthetic-key"); try settings.setEnabled(true, privacyConfirmed: true)
        let network = UAPITrackingClientTests.Network()
        network.body = try JSONSerialization.data(withJSONObject: ["tracking_number": number, "status_code": "in_transit", "tracks": [["time": "2026-11-02 10:00:00", "context": "运输中"]]])
        network.headers = ["UAPI-Credits-Charged": "40"]
        let client = UAPITrackingClient(settings: settings, network: network, cache: cache)
        let first = try await client.query(trackingNumber: number, carrierCode: nil, phone: "9276", refresh: true)
        let billing = settings.usageSnapshot()
        network.code = 500
        let second = try await client.query(trackingNumber: number, carrierCode: nil, phone: "9276", refresh: true)
        XCTAssertTrue(second.isCached); XCTAssertEqual(first.queriedAt, second.queriedAt)
        XCTAssertEqual(network.requests.count, 1); XCTAssertEqual(settings.usageSnapshot(), billing)
        network.code = 500
        let forced = UAPITrackingClient(settings: settings, network: network, cache: cache, ignoreCache: true)
        let sentBeforeForce = network.requests.count
        do { _ = try await forced.query(trackingNumber: number, carrierCode: nil, phone: "9276", refresh: true); XCTFail("Force must not return cached success on failure") } catch {}
        XCTAssertEqual(network.requests.count, sentBeforeForce + 1)
        let retained = try await client.query(trackingNumber: number, carrierCode: nil, phone: "9276", refresh: true)
        XCTAssertTrue(retained.isCached)
        try settings.saveKey("replacement-key")
        for _ in 0..<2 {
            do { _ = try await client.query(trackingNumber: number, carrierCode: nil, phone: "9276", refresh: true); XCTFail("Failure is not success") } catch {}
        }
        XCTAssertEqual(network.requests.count, sentBeforeForce + 3)
    }
}
