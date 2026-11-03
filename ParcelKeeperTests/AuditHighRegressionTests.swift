import XCTest
@testable import ParcelKeeper

final class AuditHighRegressionTests: XCTestCase {
    func testCollectionInstructionsAreNotCollectionFacts() {
        for text in ["请凭取件码完成取件", "请尽快完成取件"] {
            XCTAssertNotEqual(MallDeliveryState.resolve(latest: text), .delivered)
        }
        XCTAssertEqual(MallDeliveryState.resolve(latest: "已签收，菜鸟驿站代收"), .readyForPickup)
        for text in ["本人已取件", "已从快递柜取出", "已完成取件"] {
            XCTAssertEqual(MallDeliveryState.resolve(latest: text), .delivered)
        }
        XCTAssertNil(MallDeliveryState.resolve(latest: "尚未完成取件"))
    }

    func testForcedQueriesFailBeforeDispatchForCorruptAndOversizedCache() async throws {
        for oversized in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            try (oversized ? Data(repeating: 32, count: 8_000_001) : Data("broken".utf8))
                .write(to: directory.appendingPathComponent("success-v1.json"))
            let suite = "AuditHigh." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let phoneKeys = UAPITrackingClientTests.Keys()
            let cache = PaidTrackingCache(directory: directory, phoneKeys: { _ in phoneKeys })
            let network = UAPITrackingClientTests.Network()
            let uapi = UAPISettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
            try uapi.saveKey("synthetic-key"); try uapi.setEnabled(true, privacyConfirmed: true)
            let billing = uapi.usageSnapshot()
            do {
                _ = try await UAPITrackingClient(settings: uapi, network: network, cache: cache, ignoreCache: true)
                    .query(trackingNumber: "YT1234567890123", carrierCode: nil, phone: nil, refresh: true)
                XCTFail("Corrupt cache must block payment")
            } catch {}
            XCTAssertEqual(network.requests.count, 0)
            XCTAssertEqual(uapi.usageSnapshot(), billing)
            let tmini = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
            try tmini.saveKey("synthetic-key"); try tmini.setEnabled(true, privacyConfirmed: true)
            let usage = TminiUsageStore(directory: directory)
            let points = try usage.summary().points
            do {
                _ = try await TminiTrackingClient(settings: tmini, network: network, usage: usage, cache: cache, ignoreCache: true)
                    .query(trackingNumber: "YT1234567890123")
                XCTFail("Corrupt cache must block payment")
            } catch {}
            XCTAssertEqual(network.requests.count, 0)
            XCTAssertEqual(try usage.summary().points, points)
        }
    }
}
