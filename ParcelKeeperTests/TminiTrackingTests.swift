import XCTest
@testable import ParcelKeeper

final class TminiTrackingTests: XCTestCase {
    let number = "YT1234567890123"
    func payload(_ package: [String: Any] = [:], code: Any = "0000000000", errcode: Int? = nil) throws -> Data {
        var p: [String: Any] = ["trackingNo": number, "cpName": "圆通", "state": "TRANSPORT", "signFlag": "AUTOMATIC", "trackingDetails": [["time": "20261102100000", "context": "运输中"], ["time": "20261101100000", "context": "已签收"]]]
        p.merge(package) { _, new in new }
        var root: [String: Any] = ["code": code, "data": ["serviceCode": 0, "packageInfoList": [p]]]
        if let errcode { root["errcode"] = errcode }
        return try JSONSerialization.data(withJSONObject: root)
    }
    func testNewestEventNotOldSignedEventOrAutomaticFlag() throws {
        let result = try TminiTrackingClient.parse(payload(), expectedNumber: number)
        XCTAssertEqual(result.status, .inTransit)
        XCTAssertEqual(result.logisticsInfo, "运输中")
        XCTAssertTrue(result.queryInfo.contains("Tmini"))
        let unknown = try TminiTrackingClient.parse(payload(["state": "FUTURE", "trackingDetails": [["time": "20261102100000", "context": "新事件"]]]), expectedNumber: number)
        XCTAssertNil(unknown.status)
    }
    func testIdentityEmptyAndBadDateFailClosed() throws {
        let cases: [[String: Any]] = [["trackingNo": "OTHER12345678"], ["trackingDetails": []], ["trackingDetails": [["time": "20260230100000", "context": "运输中"]]], ["trackingDetails": [["time": "20261102100000", "context": ""]]]]
        for changes in cases {
            XCTAssertThrowsError(try TminiTrackingClient.parse(payload(changes), expectedNumber: number))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload()) as? [String: Any])
        var data = try XCTUnwrap(object["data"] as? [String: Any])
        let packages = try XCTUnwrap(data["packageInfoList"] as? [[String: Any]])
        data["packageInfoList"] = packages + packages; object["data"] = data
        XCTAssertThrowsError(try TminiTrackingClient.parse(JSONSerialization.data(withJSONObject: object), expectedNumber: number))
    }
    func testNumericZeroIsNotSuccessAndErrcodeAlwaysWins() throws {
        XCTAssertThrowsError(try TminiTrackingClient.parse(payload(code: 0), expectedNumber: number))
        for code in [11001, 11005, 11024] {
            XCTAssertThrowsError(try TminiTrackingClient.parse(payload(errcode: code), expectedNumber: number)) { error in
                XCTAssertTrue((error as? TminiError)?.stopsBatch == true)
            }
        }
    }
    func testOperateNodeConflictStrictSuccessAndDocumentedCabinetObject() throws {
        let result = try TminiTrackingClient.parse(payload(["operateTime": "20261103120000", "operateMessage": "正在派送", "cabinetLocation": ["locationSystem": "GCJ02", "latitude": "31", "longitude": "121"]]), expectedNumber: number)
        XCTAssertEqual(result.logisticsInfo, "正在派送")
        XCTAssertEqual(result.status, .outForDelivery)
        XCTAssertTrue(result.queryInfo.contains("GCJ02"))
        XCTAssertThrowsError(try TminiTrackingClient.parse(payload(["operateTime": "20261102100000", "operateMessage": "本人已取件"]), expectedNumber: number))
        XCTAssertThrowsError(try TminiTrackingClient.parse(payload(["trackingDetails": [["time": "20261102100000", "context": "运输中"], ["time": "bad", "context": "旧事件"]]]), expectedNumber: number))
        let redacted = try TminiTrackingClient.parse(payload(["cpName": "synthetic-secret", "trackingDetails": [["time": "20261102100000", "context": "synthetic-secret"]]]), expectedNumber: number, secret: "synthetic-secret")
        XCTAssertFalse(redacted.queryInfo.contains("synthetic-secret"))
        XCTAssertFalse(redacted.logisticsInfo.contains("synthetic-secret"))
    }
    func testCredentialReadbackGenerationAndSanitizedNetwork() async throws {
        let suite = "TminiTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = UAPITrackingClientTests.Keys()
        let settings = TminiSettingsService(defaults: defaults, keys: keys)
        try settings.saveKey("synthetic-tmini-secret")
        try settings.setEnabled(true, privacyConfirmed: true)
        let generation = try settings.configurationToken()
        let network = UAPITrackingClientTests.Network()
        network.body = try payload()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = TminiTrackingClient(settings: settings, network: network, usage: TminiUsageStore(directory: directory), cache: PaidTrackingCache(directory: directory))
        _ = try await client.query(trackingNumber: number)
        XCTAssertEqual(network.requests.count, 1)
        let request = try XCTUnwrap(network.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "api.tmini.net")
        XCTAssertEqual(Set(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)), ["key", "trackingNo"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("synthetic-tmini-secret"))
        for (status, expected) in [(401, TminiError.authentication), (403, .authentication), (429, .rateLimited), (500, .maintenance), (302, .invalidResponse)] {
            try settings.saveKey("synthetic-tmini-secret")
            network.code = status
            do { _ = try await client.query(trackingNumber: number); XCTFail("Expected HTTP rejection") }
            catch { XCTAssertEqual(error as? TminiError, expected) }
        }
        network.code = 200
        try settings.saveKey("replacement")
        XCTAssertThrowsError(try settings.validateConfiguration(generation))
        try settings.removeKey()
        XCTAssertFalse(try settings.hasKey())
        XCTAssertFalse(settings.isEnabled())
        network.error = URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "synthetic-tmini-secret"])
        try settings.saveKey("replacement"); try settings.setEnabled(true, privacyConfirmed: true)
        do { _ = try await client.query(trackingNumber: number); XCTFail("Expected error") }
        catch { XCTAssertFalse(error.localizedDescription.contains("synthetic-tmini-secret")) }
    }
}
