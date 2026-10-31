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
            guard !responses.isEmpty else {
                XCTFail("Unexpected network request: mock response queue exhausted")
                throw AIServiceError.unavailable
            }
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

    func testPickupAIRejectsCandidatesInsideProtectedSpans() async throws {
        try enableShipmentAI()
        for text in ["https://example.test/取件码1234", "HTTPS://example.test/?取件码=1234",
                     "www.example.test/取件码-1234", "电话：取件码1234",
                     "手机号：取件码-1234", "订单号：取件码1234",
                     "订单号码：取件码1234", "訂單號碼：取件码1234",
                     "电话：1234", "订单号码：1234", "訂單號碼：1234",
                     "😀 https://example.test/取件码—1234"] {
            network.responses = Array(repeating: (200, response("1234")), count: 3)
            do { _ = try await service.extract(text); XCTFail("Accepted protected candidate: \(text)") }
            catch let error as AIServiceError {
                guard case let .allModelsFailed(failures) = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(failures.map(\.category), [.invalidResponse, .invalidResponse, .invalidResponse], text)
            }
        }
    }

    func testPickupAIKeepsLabelsOutsideProtectedSpans() async throws {
        try enableShipmentAI()
        for text in ["https://example.test/other，取件码1234", "电话13800138000，取件码1234",
                     "订单号码987654，取件码1234", "訂單號碼987654，取件码1234",
                     "😀 取件码-1234", "取件码－1234", "取件码—1234",
                     "订单号987654 取件码-1234"] {
            network.responses = [(200, response("1234"))]
            let result = try await service.extract(text)
            XCTAssertEqual(result.code, "1234", text)
        }
    }

    func testSharedFieldProtectionVariantsAndEightDigitLabel() async throws {
        try enableShipmentAI()
        for field in ["订单", "訂單", "运单", "運單", "物流单", "物流單", "快递单", "快遞單", "手机", "手機", "电话", "電話", "单", "單"] {
            for suffix in ["号", "號", "号码", "號碼", "编号", "編號"] {
                for value in ["1234", "取件码1234", "取件码为1234", "憑證碼為1234", "核銷碼1234"] {
                    let text = "😀 " + field + suffix + "：" + value
                    network.responses = Array(repeating: (200, response("1234")), count: 3)
                    do { _ = try await service.extract(text); XCTFail("Accepted protected candidate: \(text)") }
                    catch let error as AIServiceError {
                        guard case let .allModelsFailed(failures) = error else { return XCTFail("Unexpected error: \(error)") }
                        XCTAssertEqual(failures.map(\.category), [.invalidResponse, .invalidResponse, .invalidResponse], text)
                    }
                }
            }
        }
        for label in ["取件码", "取货码", "取餐码", "提货码"] {
            for code in ["001", "12345678", "A-1", String(repeating: "A", count: 20)] {
                network.responses = [(200, response(code))]
                let result = try await service.extract("電話號碼13987654320，\(label)：\(code)")
                XCTAssertEqual(result.code, code)
            }
        }
    }

    private func enableShipmentAI() throws {
        try service.saveConfiguration(config(), privacyConfirmed: true)
        try service.reuseKey(from: nil, expectedEndpoint: config().baseURL)
    }
    private func shipmentEnvelope(_ fields: [String: Any]) throws -> String {
        let content = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        return String(data: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), encoding: .utf8)!
    }
    private func shipmentFields(info: String, status: String, time: String = "", carrier: String = "") -> [String: String] {
        ["trackingNumber": "YT1234567890123", "carrierName": carrier, "logisticsInfo": info, "status": status, "logisticsTime": time]
    }
    private func shipmentResponse(info: String, status: String, time: String = "", carrier: String = "") throws -> String {
        try shipmentEnvelope(shipmentFields(info: info, status: status, time: time, carrier: carrier))
    }
    private func assertShipmentRejected(_ fields: [String: Any], text: String) async throws {
        network.responses = Array(repeating: (200, try shipmentEnvelope(fields)), count: 3)
        do { _ = try await service.extractShipment(text); XCTFail("Must reject invalid fields") }
        catch let error as AIServiceError {
            guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(failures.map(\.category), [.invalidResponse, .invalidResponse, .invalidResponse])
        }
    }
    func testShipmentAIUsesConfiguredModelsAndGroundedFields() async throws {
        try enableShipmentAI()
        network.responses = [(200, try shipmentResponse(info: "虚构签收", status: "已签收", carrier: "圆通速递")),
                             (200, try shipmentResponse(info: "已签收", status: "已签收", carrier: "圆通速递"))]
        let result = try await service.extractShipment("圆通速递 运单号：YT1234567890123 最新物流：已签收")
        XCTAssertEqual(result.trackingNumber, "YT1234567890123")
        XCTAssertEqual(result.carrierName, "圆通速递")
        XCTAssertEqual(result.logisticsInfo, "已签收")
        XCTAssertEqual(result.status, .delivered)
        XCTAssertNil(result.logisticsTime)
        XCTAssertEqual(network.requests.count, 2)
        let models = try network.requests.map { request -> String in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
            return body["model"] as! String
        }
        XCTAssertEqual(models, ["a", "b"])
    }
    func testShipmentAITrustsSemanticCompletionAndExactEventExcerpt() async throws {
        try enableShipmentAI()
        let info = "收件人凭取件码完成取件"
        network.responses = [(200, try shipmentResponse(info: info, status: "已签收", time: "2026-10-30 10:00", carrier: "圆通速递"))]
        let result = try await service.extractShipment("圆通速递 运单号：YT1234567890123\n最新进展：2026-10-30 10:00 \(info)")
        XCTAssertEqual(result.logisticsInfo, info)
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(result.logisticsTime, ShipmentShortcutParser.date("2026-10-30 10:00"))
        XCTAssertEqual(network.requests.count, 1)
    }
    func testShipmentAIStationReceiptIsNotPersonalCompletion() async throws {
        try enableShipmentAI()
        let info = "已签收，驿站代收"
        network.responses = [(200, try shipmentResponse(info: info, status: "待取件"))]
        let result = try await service.extractShipment("运单号：YT1234567890123 \(info)")
        XCTAssertEqual(result.logisticsInfo, info)
        XCTAssertEqual(result.status, .readyForPickup)
    }
    func testShipmentAISelectsLatestEventWithoutLocalHistoryAdjudication() async throws {
        try enableShipmentAI()
        let text = "运单号：YT1234567890123\n此前：已签收\n最新进展：包裹正在返回始发仓"
        network.responses = [(200, try shipmentResponse(info: "包裹正在返回始发仓", status: "异常"))]
        let result = try await service.extractShipment(text)
        XCTAssertEqual(result.logisticsInfo, "包裹正在返回始发仓")
        XCTAssertEqual(result.status, .exception)
        XCTAssertNil(result.logisticsTime)
    }
    func testShipmentAIOnlyChecksFieldProvenanceNotCrossEventSemantics() async throws {
        try enableShipmentAI()
        // Semantic event/time selection belongs to the model. Substring validation
        // alone intentionally cannot prove that these two excerpts form a pair.
        let text = "运单号：YT1234567890123\n2026-10-29 09:00 已签收\n2026-10-30 10:00 退回寄件人"
        network.responses = [(200, try shipmentResponse(info: "已签收", status: "已签收", time: "2026-10-30 10:00"))]
        let result = try await service.extractShipment(text)
        XCTAssertEqual(result.logisticsInfo, "已签收")
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(result.logisticsTime, ShipmentShortcutParser.date("2026-10-30 10:00"))
    }
    func testShipmentAIRejectsWholeQueryEnvelopeAsEventBody() async throws {
        try enableShipmentAI()
        let progress = "快件已按约定投递，取件人凭取件码完成取件。"
        let text = "快递单号：YT1234567890123 快递公司：圆通速递 当前状态：已签收 最新时间： 最新进展：\(progress) 查询来源：百度搜索"
        try await assertShipmentRejected(shipmentFields(info: text, status: "已签收"), text: text)
        network.responses = [(200, try shipmentResponse(info: progress, status: "已签收", carrier: "圆通速递"))]
        let result = try await service.extractShipment(text)
        XCTAssertEqual(result.logisticsInfo, progress)
        XCTAssertEqual(result.status, .delivered)
        XCTAssertNil(result.logisticsTime)
    }
    func testShipmentAIRequiresEveryFieldAsStringAndLegalNonArchivedStatus() async throws {
        try enableShipmentAI()
        let text = "运单号：YT1234567890123 最新物流：已签收"
        let valid = shipmentFields(info: "已签收", status: "已签收")
        for field in ["trackingNumber", "carrierName", "logisticsInfo", "status", "logisticsTime"] {
            var missing: [String: Any] = valid
            missing.removeValue(forKey: field)
            try await assertShipmentRejected(missing, text: text)
            var wrongType: [String: Any] = valid
            wrongType[field] = 42
            try await assertShipmentRejected(wrongType, text: text)
        }
        for status in ["delivered", "已归档", "不存在", ""] {
            try await assertShipmentRejected(shipmentFields(info: "已签收", status: status), text: text)
        }
    }
    func testShipmentAIRejectsFabricatedExcerptsAndInvalidDatesOrNumbers() async throws {
        try enableShipmentAI()
        let text = "圆通速递 运单号：YT1234567890123\n2026-10-30 10:00 已签收\n时间：昨天\n联系电话13800138000"
        let valid = shipmentFields(info: "已签收", status: "已签收", time: "2026-10-30 10:00", carrier: "圆通速递")
        for (field, value) in [("trackingNumber", "SF1234567890123"), ("trackingNumber", "13800138000"),
                               ("carrierName", "顺丰速运"), ("logisticsInfo", "收件人已取件"),
                               ("logisticsTime", "2026-10-31 10:00"), ("logisticsTime", "昨天")] {
            var invalid = valid
            invalid[field] = value
            try await assertShipmentRejected(invalid, text: text)
        }
    }
    func testShipmentAIAllowsEmptyLogisticsOnlyWithEmptyStatusAndTime() async throws {
        try enableShipmentAI()
        let text = "运单号：YT1234567890123 查询时间：2026-10-30 10:00"
        network.responses = [(200, try shipmentResponse(info: "", status: ""))]
        let result = try await service.extractShipment(text)
        XCTAssertNil(result.logisticsInfo)
        XCTAssertNil(result.status)
        XCTAssertNil(result.logisticsTime)
        try await assertShipmentRejected(shipmentFields(info: "", status: "已签收"), text: text)
        try await assertShipmentRejected(shipmentFields(info: "", status: "", time: "2026-10-30 10:00"), text: text)
    }
    func testShipmentAIEmptyEventTimeDoesNotUseQueryTime() async throws {
        try enableShipmentAI()
        network.responses = [(200, try shipmentResponse(info: "收件人凭取件码完成取件", status: "已签收"))]
        let result = try await service.extractShipment("运单号：YT1234567890123 查询时间：2026-10-30 10:00\n收件人凭取件码完成取件")
        XCTAssertNil(result.logisticsTime)
        XCTAssertEqual(result.status, .delivered)
    }
    func testShipmentAIPromptDefinesIndependentSemanticContract() async throws {
        try enableShipmentAI()
        network.responses = [(200, try shipmentResponse(info: "已签收", status: "已签收"))]
        _ = try await service.extractShipment("运单号：YT1234567890123 已签收")
        let request = try XCTUnwrap(network.requests.first)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let prompt = try XCTUnwrap(messages.first?["content"])
        for requirement in ["status", "运输中", "派送中", "待取件", "已签收", "异常", "驿站代收", "凭取件码完成取件", "查询时间", "逐字", "最新事件正文"] {
            XCTAssertTrue(prompt.contains(requirement), "Missing prompt contract: \(requirement)")
        }
        XCTAssertEqual(messages.last?["content"], "运单号：YT1234567890123 已签收")
    }
    func testShipmentAIAllModelsFailInsteadOfReturningLocalParse() async throws {
        try enableShipmentAI()
        network.responses = [(429, ""), (503, ""), (200, "not JSON")]
        do { _ = try await service.extractShipment("运单号：YT1234567890123 最新物流：已签收"); XCTFail("No local fallback") }
        catch let error as AIServiceError {
            guard case let .allModelsFailed(failures) = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(failures.map(\.model), ["a", "b", "c"])
            XCTAssertEqual(failures.map(\.category), [.unavailable, .unavailable, .invalidResponse])
        }
        XCTAssertEqual(network.requests.count, 3)
    }
    func testShipmentAIAuthenticationStopsWithoutFallback() async throws {
        try enableShipmentAI()
        network.responses = [(401, "")]
        do { _ = try await service.extractShipment("运单号：YT1234567890123 已签收"); XCTFail() }
        catch { XCTAssertEqual(error as? AIServiceError, .authentication) }
        XCTAssertEqual(network.requests.count, 1)
    }
    func testShipmentAIHandlesStructuredLatestEventAndTimestampSuffix() async throws {
        try enableShipmentAI()
        let fields = ["trackingNumber": "YT1234567890123", "logisticsInfo": "退回寄件人", "logisticsTime": "2026-10-30 10:00"]
        let structured = String(data: try JSONSerialization.data(withJSONObject: fields), encoding: .utf8)!
        for text in [structured, "运单号：YT1234567890123\n2026-10-29 09:00 已签收\n退回寄件人 2026-10-30 10:00"] {
            network.responses = [(200, try shipmentResponse(info: "退回寄件人", status: "异常", time: "2026-10-30 10:00"))]
            let result = try await service.extractShipment(text)
            XCTAssertEqual(result.logisticsInfo, "退回寄件人")
            XCTAssertEqual(result.status, .exception)
            XCTAssertEqual(result.logisticsTime, ShipmentShortcutParser.date("2026-10-30 10:00"))
        }
    }
    func testShipmentAIStatusIsAnEnumNotAnExcerptOrLocalKeywordClassification() async throws {
        try enableShipmentAI()
        let text = "运单号：YT1234567890123 最新物流：已进入下一处理环节"
        for status in ShipmentStatus.allCases where status != .archived {
            network.responses = [(200, try shipmentResponse(info: "已进入下一处理环节", status: status.rawValue))]
            let result = try await service.extractShipment(text)
            XCTAssertEqual(result.status, status)
            XCTAssertEqual(result.logisticsInfo, "已进入下一处理环节")
        }
    }
    func testShipmentAITrackingNumberMustBeVerbatimBeforeNormalization() async throws {
        try enableShipmentAI()
        let text = "运单号：yt1234567890123 已签收"
        try await assertShipmentRejected(shipmentFields(info: "已签收", status: "已签收"), text: text)
        var fields = shipmentFields(info: "已签收", status: "已签收")
        fields["trackingNumber"] = "yt1234567890123"
        network.responses = [(200, try shipmentEnvelope(fields))]
        let result = try await service.extractShipment(text)
        XCTAssertEqual(result.trackingNumber, "YT1234567890123")
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
