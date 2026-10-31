import XCTest
@testable import ParcelKeeper

final class UAPITrackingClientTests: XCTestCase {
    final class Keys: AIKeyStore {
        var value: String?
        var failure = false
        func read() throws -> String? { if failure { throw AIServiceError.keychain }; return value }
        func save(_ key: String) throws { if failure { throw AIServiceError.keychain }; value = key }
        func delete() throws { if failure { throw AIServiceError.keychain }; value = nil }
        func read(endpoint: String) throws -> String? { XCTFail("UAPI must use its isolated service"); return nil }
        func save(_ key: String, endpoint: String) throws { XCTFail("Unexpected endpoint binding") }
        func delete(endpoint: String) throws { XCTFail("Unexpected endpoint binding") }
    }
    final class Network: AINetworking {
        var requests: [URLRequest] = []
        var code = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: Error?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            if let error { throw error }
            return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
    }
    var defaults: UserDefaults!
    var suite: String!
    var keys: Keys!
    var settings: UAPISettingsService!
    var network: Network!
    var client: UAPITrackingClient!
    let number = "YT1234567890123"
    override func setUp() {
        super.setUp()
        suite = "UAPITrackingClientTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        keys = Keys(); network = Network()
        settings = UAPISettingsService(defaults: defaults, keys: keys)
        client = UAPITrackingClient(settings: settings, network: network)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    func enable() throws {
        try settings.saveKey("synthetic-uapi-key")
        try settings.setEnabled(true, privacyConfirmed: true)
    }
    func payload(_ changes: [String: Any] = [:]) throws {
        var object: [String: Any] = ["tracking_number": number, "carrier_code": "yuantong", "carrier_name": "圆通速递", "status_code": "in_transit", "is_completed": false, "track_count": 2, "tracks": [["time": "2026-10-30 10:00:00", "context": "正在发往上海"], ["time": "2026-10-29 09:00:00", "context": "已揽收"]]]
        object.merge(changes) { _, new in new }
        network.body = try JSONSerialization.data(withJSONObject: object)
    }
    func query(phone: String? = nil) async throws -> UAPITrackingResult {
        try await client.query(trackingNumber: number, carrierCode: nil, phone: phone, refresh: false)
    }
    func assertError(_ expected: UAPIError, phone: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await query(phone: phone); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? UAPIError, expected, file: file, line: line) }
    }
    func testConsentAndKeyAreSeparateAndKeyNeverEntersDefaults() throws {
        XCTAssertFalse(settings.isEnabled())
        XCTAssertFalse(try settings.hasKey())
        XCTAssertThrowsError(try settings.setEnabled(true)) { XCTAssertEqual($0 as? UAPIError, .privacyConsentRequired) }
        try enable()
        XCTAssertTrue(settings.isEnabled())
        XCTAssertTrue(try settings.hasKey())
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("synthetic-uapi-key"))
        XCTAssertThrowsError(try settings.saveKey("bad\r\nkey"))
        try settings.removeKey()
        XCTAssertFalse(try settings.hasKey())
        XCTAssertFalse(settings.isEnabled())
    }
    func testDisabledOrMissingKeyNeverSendsAnonymousRequest() async throws {
        await assertError(.notConfigured)
        try settings.setEnabled(true, privacyConfirmed: true)
        await assertError(.notConfigured)
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testCredentialFailuresAreSanitized() throws {
        keys.failure = true
        XCTAssertThrowsError(try settings.hasKey()) { XCTAssertEqual($0 as? UAPIError, .keychain) }
        XCTAssertThrowsError(try settings.saveKey("synthetic")) { XCTAssertEqual($0 as? UAPIError, .keychain) }
    }
    func testRequestContractAndFullReadableHistory() async throws {
        try enable(); try payload()
        let before = Date()
        let result = try await client.query(trackingNumber: number, carrierCode: "yuantong", phone: "1234", refresh: true)
        let request = try XCTUnwrap(network.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "uapis.cn")
        XCTAssertEqual(request.url?.path, "/api/v1/misc/tracking/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-uapi-key")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }), ["tracking_number": number, "carrier_code": "yuantong", "phone": "1234", "refresh": "true"])
        XCTAssertEqual(result.status, .inTransit)
        XCTAssertEqual(result.logisticsInfo, "正在发往上海")
        XCTAssertEqual(result.logisticsTime, ShipmentShortcutParser.date("2026-10-30 10:00:00"))
        XCTAssertTrue(result.queryInfo.contains("2026-10-29 09:00:00 已揽收"))
        XCTAssertFalse(result.queryInfo.contains("synthetic-uapi-key"))
        XCTAssertTrue(result.queriedAt >= before)
        XCTAssertEqual(network.requests.count, 1)
    }
    func testPhoneMustBeExactlyFourASCIIDigitsBeforeNetwork() async throws {
        try enable()
        for phone in ["", "123", "12345", "１２３４", "1234&x=1", "1234\n", " 1234"] { await assertError(.invalidPhone, phone: phone) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testUnknownStatusAndMissingOptionalFieldsDoNotGuessFromProse() async throws {
        try enable()
        network.body = try JSONSerialization.data(withJSONObject: ["tracking_number": number, "future_field": true, "status_code": "future_status", "tracks": [["time": "2026-10-30 10:00", "context": "已签收"]]])
        let result = try await query()
        XCTAssertNil(result.status)
        XCTAssertEqual(result.carrierName, "")
        XCTAssertEqual(result.carrierCode, "")
    }
    func testCompletedAndKnownStateMapping() async throws {
        try enable()
        for (code, expected) in [("pending", ShipmentStatus.inTransit), ("picked_up", .inTransit), ("out_for_delivery", .outForDelivery), ("exception", .exception), ("delivered", .delivered)] {
            try payload(["status_code": code, "is_completed": code == "delivered"])
            let result = try await query(); XCTAssertEqual(result.status, expected)
        }
        try payload(["status_code": "unknown", "is_completed": true])
        let complete = try await query(); XCTAssertEqual(complete.status, .delivered)
        try payload(["status_code": "unknown", "status": "待取件"])
        let pickup = try await query(); XCTAssertEqual(pickup.status, .readyForPickup)
    }
    func testContradictionsWrongNumberAndBadDatesRejected() async throws {
        try enable()
        let changes: [[String: Any]] = [["is_completed": true], ["status_code": "delivered"], ["tracking_number": "SF1234567890123"], ["completed_at": "yesterday"], ["is_completed": "true"], ["tracks": [["time": "yesterday", "context": "运输中"]]], ["tracks": [["time": "2026-10-30 10:00", "context": " "]]]]
        for change in changes {
            try payload(change); await assertError(.invalidResponse)
        }
        try payload(["tracks": []]); await assertError(.noData)
    }
    func testValidOutOfOrderHistoryIsSortedAndTiesAreRejected() async throws {
        try enable()
        try payload(["tracks": [["time": "2026-10-29 09:00", "context": "已揽收"], ["time": "2026-10-30 10:00", "context": "正在发往上海"]]])
        let result = try await query(); XCTAssertEqual(result.logisticsInfo, "正在发往上海")
        try payload(["tracks": [["time": "2026-10-30 10:00", "context": "正在发往上海"], ["time": "2026-10-30 10:00", "context": "已签收"]]])
        await assertError(.invalidResponse)
    }
    func testCountAndChineseCompletionContradictionsAreRejected() async throws {
        try enable()
        let contradictions: [[String: Any]] = [["track_count": 1], ["status": "已完成"], ["status_code": "delivered", "is_completed": true, "status": "待取件"], ["status_code": "unknown", "is_completed": true, "status": "运输中"]]
        for fields in contradictions {
            try payload(fields)
            await assertError(.invalidResponse)
        }
        try payload(["status_code": "unknown", "is_completed": true, "status": "已完成"])
        let result = try await query()
        XCTAssertEqual(result.status, .delivered)
    }
    func testHTTPFailuresAreTypedAndNeverRetried() async throws {
        try enable()
        for (code, expected) in [(401, UAPIError.authentication), (403, .authentication), (402, .quota), (404, .noData), (500, .unavailable), (302, .invalidResponse)] {
            network.code = code; await assertError(expected)
        }
        network.code = 429; network.headers = ["Retry-After": "120"]
        await assertError(.rateLimited(120))
        XCTAssertEqual(network.requests.count, 7)
        XCTAssertTrue(UAPIError.authentication.stopsBatch)
        XCTAssertTrue(UAPIError.quota.stopsBatch)
        XCTAssertTrue(UAPIError.rateLimited(nil).stopsBatch)
        XCTAssertFalse(UAPIError.noData.stopsBatch)
        XCTAssertFalse(UAPIError.unavailable.stopsBatch)
    }
    func testCreditHeadersPersistWithoutAnotherRequest() async throws {
        try enable(); try payload()
        network.headers = ["RateLimit": "\"billing-key-rate\";r=3;t=1,\"billing-quota\";r=2800;uapi-unit=\"credits\";t=86400,\"billing-balance\";r=860;uapi-unit=\"cents\"", "UAPI-Credits-Charged": "40"]
        _ = try await query()
        let usage = try XCTUnwrap(settings.usageSnapshot())
        XCTAssertEqual(usage.remainingCredits, 2800)
        XCTAssertEqual(usage.chargedCredits, 40)
        XCTAssertEqual(network.requests.count, 1)
        XCTAssertEqual(UAPISettingsService(defaults: defaults, keys: keys).usageSnapshot(), usage)
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("synthetic-uapi-key"))
    }

    func testCreditHeadersOnQuotaFailureAndMissingHeaders() async throws {
        try enable(); try payload()
        network.code = 402
        network.headers = ["RateLimit": "\"billing-quota\";r=0;uapi-unit=\"credits\"", "UAPI-Credits-Charged": "0"]
        await assertError(.quota)
        let previous = try XCTUnwrap(settings.usageSnapshot())
        XCTAssertEqual(previous.remainingCredits, 0)
        network.code = 200; network.headers = [:]
        _ = try await query()
        XCTAssertEqual(settings.usageSnapshot(), previous)
    }

    func testCreditParserRejectsInvalidOrAmbiguousNumbers() {
        for header in ["\"billing-balance\";r=860;uapi-unit=\"cents\"", "\"billing-key-rate\";r=3", "\"billing-quota\";r=-1;uapi-unit=\"credits\"", "\"billing-quota\";r=1.5;uapi-unit=\"credits\"", "\"billing-quota\";r=9999999999999999999999999;uapi-unit=\"credits\"", "\"billing-quota\";r=8;uapi-unit=\"cents\"", "\"billing-quota\";r=8;r=9;uapi-unit=\"credits\"", "\"billing-quota\";r=8;uapi-unit=\"credits\",\"billing-quota\";r=9;uapi-unit=\"credits\""] {
            let response = HTTPURLResponse(url: URL(string: "https://uapis.cn")!, statusCode: 200, httpVersion: nil, headerFields: ["RateLimit": header])!
            XCTAssertNil(UAPIUsageSnapshot(response: response))
        }
    }

    func testChangingKeyClearsUsageAndRejectsOldInFlightResponse() async throws {
        try enable(); try payload()
        let generation = settings.usageGeneration()
        network.headers = ["RateLimit": "\"billing-quota\";r=80;uapi-unit=\"credits\""]
        _ = try await query()
        XCTAssertNotNil(settings.usageSnapshot())
        try settings.saveKey("new-synthetic-key")
        XCTAssertNil(settings.usageSnapshot())
        let response = HTTPURLResponse(url: URL(string: "https://uapis.cn")!, statusCode: 200, httpVersion: nil, headerFields: network.headers)!
        settings.recordUsage(response, generation: generation)
        XCTAssertNil(settings.usageSnapshot())
        _ = try await query()
        XCTAssertNotNil(settings.usageSnapshot())
        try settings.removeKey()
        XCTAssertNil(settings.usageSnapshot())
    }

    func testOlderResponseCannotOverwriteNewerSnapshotAndPartialHeadersStayUnknown() throws {
        try enable()
        let generation = settings.usageGeneration()
        func response(_ remaining: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://uapis.cn")!, statusCode: 200, httpVersion: nil,
                            headerFields: ["RateLimit": "\"billing-quota\";r=\(remaining);uapi-unit=\"credits\""])!
        }
        settings.recordUsage(response(40), generation: generation, requestStartedAt: Date(timeIntervalSince1970: 200))
        settings.recordUsage(response(80), generation: generation, requestStartedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(settings.usageSnapshot()?.remainingCredits, 40)
        let partial = HTTPURLResponse(url: URL(string: "https://uapis.cn")!, statusCode: 200, httpVersion: nil,
                                      headerFields: ["UAPI-Credits-Charged": "0"])!
        settings.recordUsage(partial, generation: generation)
        XCTAssertNil(settings.usageSnapshot()?.remainingCredits)
        XCTAssertEqual(settings.usageSnapshot()?.chargedCredits, 0)
        keys.failure = true
        XCTAssertThrowsError(try settings.saveKey("replacement"))
        XCTAssertEqual(settings.usageSnapshot()?.chargedCredits, 0)
    }

    func testMalformedAndCancellationDoNotLeakProviderErrors() async throws {
        try enable()
        network.body = Data("not json".utf8); await assertError(.invalidResponse)
        network.error = URLError(.cancelled); await assertError(.cancelled)
        network.error = URLError(.timedOut); await assertError(.unavailable)
        network.error = NSError(domain: "synthetic-secret", code: 1); await assertError(.unavailable)
        XCTAssertEqual(network.requests.count, 4)
    }
}
