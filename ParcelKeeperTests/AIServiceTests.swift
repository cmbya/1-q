import XCTest
@testable import ParcelKeeper

final class AIServiceTests: XCTestCase {
    final class Keys: AIKeyStore {
        var value: String? = "synthetic-key"
        var bound: [String: String] = [:]
        var failSave = false
        func read(endpoint: String) throws -> String? { bound[endpoint] }
        func save(_ key: String, endpoint: String) throws { if failSave { throw AIServiceError.keychain }; bound[endpoint] = key }
        func delete(endpoint: String) throws { bound.removeValue(forKey: endpoint) }
        func read() throws -> String? { value }
        func save(_ key: String) throws { value = key }
        func delete() throws { value = nil }
    }
    final class Network: AINetworking {
        var requests: [URLRequest] = []
        var responses: [(Int, String)] = []
        var error: Error?
        var onRequest: (() throws -> Void)?
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            try onRequest?()
            if let error = error { throw error }
            let (status, body) = responses.removeFirst()
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    var defaults: UserDefaults!
    var network: Network!
    var service: AIService!
    var keys: Keys!
    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        network = Network()
        keys = Keys()
        service = AIService(defaults: defaults, keys: keys, network: network)
    }
    func config() -> AIConfiguration {
        AIConfiguration(name: "test", baseURL: "https://example.invalid/v1", models: ["a", "b", "c"], defaultModel: "a", fallbackModels: ["b", "c"], enabled: true)
    }
    func response(_ code: String, _ location: String = "") -> String {
        let content = try! JSONSerialization.data(withJSONObject: ["code": code, "location": location, "source": ""])
        let envelope: [String: Any] = ["choices": [["message": ["content": String(data: content, encoding: .utf8)!]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: envelope), encoding: .utf8)!
    }
    func testAILabeledHyphenCodeAcceptedButSuffixRejected() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(200, response("3-4-1366", "菜鸟驿站"))]
        let text = "已送达菜鸟驿站\n包裹待签收【取件码-3-4-1366】，手机号已加密"
        let result = try await service.extract(text)
        XCTAssertEqual(result.code, "3-4-1366")
        XCTAssertEqual(result.location, "菜鸟驿站")
        network.responses = [(200, response("4-1366")), (200, response("4-1366")), (200, response("4-1366"))]
        do { _ = try await service.extract(text); XCTFail("Must reject a suffix of the real code") }
        catch { guard case AIServiceError.allModelsFailed = error else { return XCTFail("Unexpected error") } }
    }

    func testShipmentAIUsesConfiguredModelsAndGroundedFields() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        func envelope(_ fields: [String: String]) throws -> String {
            let content = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
            return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), encoding: .utf8)!
        }
        network.responses = [(200, try envelope(["trackingNumber": "YT1234567890123", "carrierName": "圆通速递", "logisticsInfo": "虚构签收", "logisticsTime": ""])),
                             (200, try envelope(["trackingNumber": "YT1234567890123", "carrierName": "圆通速递", "logisticsInfo": "已签收", "logisticsTime": ""]))]
        let result = try await service.extractShipment("圆通速递 运单号：YT1234567890123 最新物流：已签收")
        XCTAssertEqual(result.trackingNumber, "YT1234567890123")
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(network.requests.count, 2)
    }

    private func shipmentResponse(info: String, time: String) throws -> String {
        let fields = ["trackingNumber": "YT1234567890123", "carrierName": "", "logisticsInfo": info, "logisticsTime": time]
        let content = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), encoding: .utf8)!
    }
    func testShipmentAIRejectsHistoricalReceiptAndCrossEventTimePairing() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        let text = "运单号：YT1234567890123\n2026-10-29 09:00 已签收\n2026-10-30 10:00 退回寄件人"
        for (info, time) in [("已签收", "2026-10-30 10:00"), ("已签收", "2026-10-29 09:00"),
                             ("已签收", ""), ("退回寄件人", "2026-10-29 09:00"), ("退回寄件人", "")] {
            network.responses = Array(repeating: (200, try shipmentResponse(info: info, time: time)), count: 3)
            do { _ = try await service.extractShipment(text); XCTFail("accepted historical/mismatched pair") }
            catch let error as AIServiceError {
                guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error: \(error)") }
                XCTAssertEqual(failures.map(\.category), [.invalidResponse, .invalidResponse, .invalidResponse])
            }
        }
        network.responses = [(200, try shipmentResponse(info: "退回寄件人", time: "2026-10-30 10:00"))]
        let latest = try await service.extractShipment(text)
        XCTAssertEqual(latest.status, .exception)
        XCTAssertEqual(latest.logisticsTime, ShipmentShortcutParser.date("2026-10-30 10:00"))
    }
    func testShipmentAICannotRemoveStationQualifierOrFillAmbiguousHistory() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for text in ["运单号：YT1234567890123 已签收，驿站代收", "运单号：YT1234567890123\n已签收\n退回"] {
            network.responses = Array(repeating: (200, try shipmentResponse(info: "已签收", time: "")), count: 3)
            do { _ = try await service.extractShipment(text); XCTFail("must reject completion") }
            catch let error as AIServiceError {
                guard case .allModelsFailed = error else { return XCTFail("wrong error: \(error)") }
            }
        }
        network.responses = [(200, try shipmentResponse(info: "已签收，驿站代收", time: ""))]
        let pickup = try await service.extractShipment("运单号：YT1234567890123 已签收，驿站代收")
        XCTAssertEqual(pickup.status, .readyForPickup)
    }
    func testShipmentAIHandlesStructuredLatestEventAndTimestampPrefix() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        let fields = ["trackingNumber": "YT1234567890123", "logisticsInfo": "退回寄件人", "logisticsTime": "2026-10-30 10:00"]
        let structured = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        for text in [structured, "运单号：YT1234567890123\n2026-10-29 09:00 已签收\n退回寄件人 2026-10-30 10:00"] {
            network.responses = [(200, try shipmentResponse(info: "退回寄件人", time: "2026-10-30 10:00"))]
            let result = try await service.extractShipment(text)
            XCTAssertEqual(result.logisticsInfo, "退回寄件人")
            XCTAssertEqual(result.status, .exception)
        }
    }
    func testShipmentAIMultipleParcelsNeverSent() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        do { _ = try await service.extractShipment("运单号：YT1234567890123 SF1234567890123 已签收"); XCTFail() }
        catch { XCTAssertTrue(error is ShipmentShortcutError) }
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testConsentAndPersistence() throws {
        XCTAssertThrowsError(try service.saveConfiguration(config()))
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        XCTAssertEqual(service.loadConfiguration().fallbackModels, ["b", "c"])
        XCTAssertFalse(String(data: defaults.data(forKey: "ai.configuration")!, encoding: .utf8)!.contains("synthetic-key"))
    }
    func testDisabledDoesNotRequest() async {
        do { _ = try await service.extract("00123"); XCTFail() } catch { XCTAssertEqual(error as? AIServiceError, .disabled) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testFallbackAndGrounding() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(429, ""), (200, response("00123", "虚构地址")), (200, response("00123", "测试柜"))]
        let result = try await service.extract("取件码00123，地点测试柜")
        XCTAssertEqual(result.model, "c")
        XCTAssertEqual(result.failures.map(\.category), [.unavailable, .invalidResponse])
        XCTAssertEqual(network.requests.count, 3)
        XCTAssertEqual(network.requests.first?.url?.path, "/v1/chat/completions")
    }
    func testMultilineSinglePickupKeepsLocation() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(200, response("00123", "测试柜"))]
        let result = try await service.extract("取件码 00123\n地点：测试柜")
        XCTAssertEqual(result.location, "测试柜")
    }

    func testAuthenticationStops() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(401, "")]
        do { _ = try await service.extract("00123"); XCTFail() } catch { XCTAssertEqual(error as? AIServiceError, .authentication) }
        XCTAssertEqual(network.requests.count, 1)
    }
    func testEmptyModelsPreserveConfiguration() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(200, "{\"data\":[]}")]
        do { _ = try await service.refreshModels(); XCTFail() } catch { XCTAssertEqual(error as? AIServiceError, .invalidResponse) }
        XCTAssertEqual(service.loadConfiguration(), config())
        XCTAssertEqual(network.requests.first?.url?.path, "/v1/models")
    }
    func testHTTPRejected() async throws {
        var c = config(); c.baseURL = "http://localhost:8080/v1"
        try service.saveConfiguration(c, privacyConfirmed: true)
        do { _ = try await service.extract("00123"); XCTFail() } catch { XCTAssertEqual(error as? AIServiceError, .insecureHTTP) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testAllFailuresAreStructuredAndSafe() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(429, "secret response"), (503, "secret response"), (200, "secret response")]
        do { _ = try await service.extract("00123"); XCTFail() }
        catch let error as AIServiceError {
            guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(failures.map(\.model), ["a", "b", "c"])
            XCTAssertEqual(failures.map(\.category), [.unavailable, .unavailable, .invalidResponse])
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }
    func testClientErrorsDoNotFallback() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for status in [400, 404, 422, 403] {
            network.requests = []
            network.responses = [(status, "sensitive body")]
            do { _ = try await service.extract("00123"); XCTFail() }
            catch {
                XCTAssertEqual(error as? AIServiceError, status == 403 ? .authentication : .configuration)
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            }
            XCTAssertEqual(network.requests.count, 1)
        }
    }
    func testTimeoutFallsBackAcrossModels() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.error = URLError(.timedOut)
        do { _ = try await service.extract("00123"); XCTFail() }
        catch let error as AIServiceError {
            guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error") }
            XCTAssertEqual(failures.map(\.category), [.unavailable, .unavailable, .unavailable])
            XCTAssertEqual(network.requests.count, 3)
        }
    }
    func testCancellationDoesNotFallback() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.error = URLError(.cancelled)
        do { _ = try await service.extract("00123"); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .cancelled) }
        XCTAssertEqual(network.requests.count, 1)
    }
    func testMissingKeyStopsBeforeNetwork() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        try service.removeKey(expectedEndpoint: config().baseURL)
        do { _ = try await service.extract("00123"); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .keyBindingRequired) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testEndpointChangeClearsOldModelsAndRequiresConsent() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        var changed = config(); changed.baseURL = "https://other.invalid/v1"
        XCTAssertThrowsError(try service.saveConfiguration(changed))
        try service.saveConfiguration(changed, privacyConfirmed: true)
        XCTAssertTrue(service.loadConfiguration().models.isEmpty)
        do { _ = try await service.extract("00123"); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .configuration) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testUnsafeEndpointsRejected() async throws {
        for base in ["https://user:pass@example.invalid/v1", "https://example.invalid/v1?key=x", "https://example.invalid/v1#x"] {
            let localDefaults = UserDefaults(suiteName: UUID().uuidString)!
            let localService = AIService(defaults: localDefaults, keys: Keys(), network: network)
            var c = config(); c.baseURL = base
            try localService.saveConfiguration(c, privacyConfirmed: true)
            do { _ = try await localService.extract("00123"); XCTFail() }
            catch { XCTAssertEqual(error as? AIServiceError, .configuration) }
        }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testRedirectDelegateRefusesRedirect() {
        let delegate = AIRedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let url = URL(string: "https://example.invalid")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: nil)!
        let redirected = URLRequest(url: URL(string: "https://third-party.invalid")!)
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            called = true
            XCTAssertNil($0)
        }
        XCTAssertTrue(called)
        session.invalidateAndCancel()
    }

    func testRefreshRejectsConcurrentConfigurationChange() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        var changed = config(); changed.name = "changed"; changed.fallbackModels = ["c"]
        network.responses = [(200, "{\"data\":[{\"id\":\"new\"}]}")]
        network.onRequest = { try self.service.saveConfiguration(changed) }
        do { _ = try await service.refreshModels(); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .configuration) }
        XCTAssertEqual(service.loadConfiguration(), changed)
    }
    func testMissingDefaultAndUnavailableModelFallBack() async throws {
        var c = config(); c.models = ["b", "c"]
        try service.saveConfiguration(c, privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: c.baseURL)
        network.responses = [(404, "{\"error\":{\"code\":\"model_not_found\",\"message\":\"secret\"}}"), (200, response("00123"))]
        let result = try await service.extract("取件码 00123")
        XCTAssertEqual(result.model, "c")
        XCTAssertEqual(result.failures.map(\.category), [.modelUnavailable, .modelUnavailable])
        XCTAssertEqual(result.failures.map(\.model), ["a", "b"])
        XCTAssertEqual(service.loadConfiguration(), c)
    }
    func testErrorCodeRequiresExactAllowlistedField() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for body in ["{\"error\":{\"message\":\"model_not_found\"}}", "{\"error\":{\"code\":\"model_not_found_extra\"}}", "{\"code\":\"model_not_found\"}"] {
            network.requests = []; network.responses = [(404, body)]
            do { _ = try await service.extract("00123"); XCTFail() }
            catch { XCTAssertEqual(error as? AIServiceError, .configuration) }
            XCTAssertEqual(network.requests.count, 1)
        }
    }
    func testUnsafeCodesRejected() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for (text, code) in [("电话 13800138000", "13800138000"), ("订单号 123456", "123456"), ("https://example.com/123456", "123456")] {
            network.responses = Array(repeating: (200, response(code)), count: 3)
            do { _ = try await service.extract(text); XCTFail() }
            catch let error as AIServiceError {
                guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error") }
                XCTAssertEqual(failures.map(\.category), [.invalidResponse, .invalidResponse, .invalidResponse])
            }
        }
    }
    func testMultipleRecordsDoNotMixLocations() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        network.responses = [(200, response("00123", "乙柜"))]
        let result = try await service.extract("取件码 00123 地点甲柜\n取件码 00456 地点乙柜")
        XCTAssertEqual(result.code, "00123")
        XCTAssertEqual(result.location, "")
        XCTAssertEqual(result.source, "")
    }

    func testAdjacentChineseAndLocalFieldContext() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for (text, code) in [("取件码00123地点测试柜", "00123"),
                             ("电话13800138000，取件码12345678，订单号987654", "12345678"),
                             ("取货码：87654321 电话13800138000", "87654321")] {
            network.responses = [(200, response(code))]
            let result = try await service.extract(text)
            XCTAssertEqual(result.code, code)
        }
        for (text, code) in [("电话13800138000 取件码00123", "13800138000"),
                             ("订单号123456，取件码00123", "123456"),
                             ("数字12345678", "12345678"),
                             ("取件码13800138000", "13800138000"),
                             ("https://example.com/123456", "123456")] {
            network.responses = Array(repeating: (200, response(code)), count: 3)
            do { _ = try await service.extract(text); XCTFail("accepted \(text)") }
            catch let error as AIServiceError {
                guard case .allModelsFailed = error else { return XCTFail("wrong error: \(error)") }
            }
        }
    }
    func testMixedPickupLabelsClearLocationAndSource() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        let content = try JSONSerialization.data(withJSONObject: ["code": "00123", "location": "乙柜", "source": "乙店"])
        let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(data: content, encoding: .utf8)!]]]])
        for other in ["取货码", "取餐码", "提货码", "取件码"] {
            network.responses = [(200, String(data: body, encoding: .utf8)!)]
            let result = try await service.extract("取件码00123甲柜，\(other)00456乙柜乙店")
            XCTAssertEqual(result.location, "")
            XCTAssertEqual(result.source, "")
        }
    }
    func testConnectionErrorsFallbackButTLSDoesNot() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        for code: URLError.Code in [.cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet] {
            network.requests = []; network.error = URLError(code)
            do { _ = try await service.extract("00123"); XCTFail() }
            catch let error as AIServiceError {
                guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error") }
                XCTAssertEqual(failures.map(\.category), [.unavailable, .unavailable, .unavailable])
            }
            XCTAssertEqual(network.requests.count, 3)
        }
        network.requests = []; network.error = URLError(.serverCertificateUntrusted)
        do { _ = try await service.extract("00123"); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .configuration) }
        XCTAssertEqual(network.requests.count, 1)
    }

    func testLegacyAndChangedEndpointNeverSendUnconfirmedKey() async throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        do { _ = try await service.refreshModels(); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .keyBindingRequired) }
        XCTAssertTrue(network.requests.isEmpty)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
        var changed = config(); changed.baseURL = "https://other.invalid/v1"; changed.enabled = false
        try service.saveConfiguration(changed)
        do { _ = try await service.refreshModels(); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .keyBindingRequired) }
        XCTAssertTrue(network.requests.isEmpty)
        XCTAssertNotNil(keys.value)
        XCTAssertNotNil(keys.bound[config().baseURL])
        try service.reuseKey(from: config().baseURL, expectedEndpoint: changed.baseURL)
        network.responses = [(200, "{\"data\":[{\"id\":\"new\"}]}")]
        _ = try await service.refreshModels()
        XCTAssertEqual(network.requests.count, 1)
    }
    func testKeyWritesFailClosedAndRequireCurrentEndpoint() throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        XCTAssertThrowsError(try service.saveKey("new", expectedEndpoint: "https://wrong.invalid"))
        keys.failSave = true
        XCTAssertThrowsError(try service.reuseKey(from: nil, expectedEndpoint: config().baseURL))
        XCTAssertNil(keys.bound[config().baseURL])
        XCTAssertNotNil(keys.value)
    }

}
