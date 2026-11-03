import XCTest
@testable import ParcelKeeper

final class TminiUsageTests: XCTestCase {
    func testPersistenceAndConcurrentInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TminiUsageStore(directory: directory)
        XCTAssertEqual(try store.summary().points, 0)
        let first = Date(timeIntervalSince1970: 100)
        try store.recordDispatch(now: first)
        let reopened = TminiUsageStore(directory: directory)
        XCTAssertEqual(try reopened.summary().points, 4)
        let errors = NSLock()
        var failed = false
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { try TminiUsageStore(directory: directory).recordDispatch() }
            catch { errors.lock(); failed = true; errors.unlock() }
        }
        XCTAssertFalse(failed)
        let result = try reopened.summary()
        XCTAssertEqual(result.queries, 21)
        XCTAssertEqual(result.points, 84)
        XCTAssertEqual(result.firstRecordedAt, first)
        XCTAssertNotNil(result.lastRecordedAt)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("tmini-usage.json"))) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["queries", "firstRecordedAt", "lastRecordedAt"])
    }
    func testCorruptionIsPreservedAndOverflowRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tmini-usage.json")
        let broken = Data("broken".utf8)
        try broken.write(to: file)
        let store = TminiUsageStore(directory: directory)
        XCTAssertThrowsError(try store.summary())
        XCTAssertThrowsError(try store.recordDispatch())
        XCTAssertEqual(try Data(contentsOf: file), broken)
        let full = TminiUsageSummary(queries: Int64.max / 4, firstRecordedAt: Date(), lastRecordedAt: Date())
        try JSONEncoder().encode(full).write(to: file)
        XCTAssertThrowsError(try store.recordDispatch())
        XCTAssertEqual(try store.summary().queries, full.queries)
    }
    func testOnlyDispatchCountsIncludingFailuresAndCredentialReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TminiUsageTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let settings = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
        let network = UAPITrackingClientTests.Network()
        let store = TminiUsageStore(directory: directory)
        let client = TminiTrackingClient(settings: settings, network: network, usage: store)
        do { _ = try await client.query(trackingNumber: "YT1234567890123"); XCTFail() } catch {}
        try settings.saveKey("synthetic-key"); try settings.setEnabled(true, privacyConfirmed: true)
        do { _ = try await client.query(trackingNumber: "bad number"); XCTFail() } catch {}
        XCTAssertEqual(try store.summary().queries, 0)
        XCTAssertEqual(network.requests.count, 0)
        network.code = 401
        for _ in 0..<2 {
            do { _ = try await client.query(trackingNumber: "YT1234567890123"); XCTFail() } catch {}
        }
        network.error = URLError(.timedOut)
        do { _ = try await client.query(trackingNumber: "YT1234567890123"); XCTFail() } catch {}
        XCTAssertEqual(try store.summary().points, 12)
        try settings.saveKey("replacement-key"); try settings.removeKey()
        XCTAssertEqual(try store.summary().points, 12)
        network.error = nil
        try settings.saveKey("synthetic-key"); try settings.setEnabled(true, privacyConfirmed: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("tmini-usage.json"))
        let sent = network.requests.count
        do { _ = try await client.query(trackingNumber: "YT1234567890123"); XCTFail() }
        catch { XCTAssertEqual(error as? TminiError, .accounting) }
        XCTAssertEqual(network.requests.count, sent)
    }
}
