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

    func testQueriesIgnoreCorruptAndOversizedLegacyCacheWithoutChangingIt() async throws {
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
            let original = try Data(contentsOf: directory.appendingPathComponent("success-v1.json"))
            phoneKeys.failure = true // No obsolete cache identity Keychain dependency either.
            network.body = try JSONSerialization.data(withJSONObject: ["tracking_number": "YT1234567890123", "status_code": "in_transit", "tracks": [["time": "2026-11-02 10:00:00", "context": "运输中"]]])
            network.headers = ["UAPI-Credits-Charged": "40"]
            let client = UAPITrackingClient(settings: uapi, network: network, cache: cache)
            for _ in 0..<2 {
                let result = try await client.query(trackingNumber: "YT1234567890123", carrierCode: nil, phone: "9276", refresh: false)
                XCTAssertFalse(result.isCached)
            }
            XCTAssertEqual(network.requests.count, 2)
            XCTAssertEqual(uapi.usageSnapshot()?.chargedCredits, 40)
            let tmini = TminiSettingsService(defaults: defaults, keys: UAPITrackingClientTests.Keys())
            try tmini.saveKey("synthetic-key"); try tmini.setEnabled(true, privacyConfirmed: true)
            let usage = TminiUsageStore(directory: directory)
            let points = try usage.summary().points
            network.body = try JSONSerialization.data(withJSONObject: ["code": "0000000000", "data": ["serviceCode": 0, "packageInfoList": [["trackingNo": "YT1234567890123", "state": "TRANSPORT", "trackingDetails": [["time": "20261102100000", "context": "运输中"]]]]]])
            let tminiClient = TminiTrackingClient(settings: tmini, network: network, usage: usage, cache: cache)
            for _ in 0..<2 {
                let result = try await tminiClient.query(trackingNumber: "YT1234567890123")
                XCTAssertFalse(result.isCached)
            }
            XCTAssertEqual(network.requests.count, 4)
            XCTAssertEqual(try usage.summary().points, points + 8)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("success-v1.json")), original)
        }
    }
}
