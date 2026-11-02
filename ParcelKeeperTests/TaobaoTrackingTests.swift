import XCTest
@testable import ParcelKeeper

final class TaobaoTrackingTests: XCTestCase {
    private let number = "SF1234567890123"
    private var now: Date { ISO8601DateFormatter().date(from: "2026-01-02T12:00:00+08:00")! }

    private func node(_ time: String, _ title: String = "运输中", _ text: String = "测试轨迹") -> [String: Any] {
        ["subtitle": time, "title": title, "labelDesc": ["text": text]]
    }
    private func fields(_ nodes: [[String: Any]]) -> [String: Any] {
        ["mailNo": number, "logisticCompany": ["mailNo": number, "name": "顺丰"], "multiStage": nodes]
    }
    private func html(_ fields: [String: Any], key: String = "newLogistics") throws -> Data {
        let object: [String: Any] = ["result": ["data": [key: ["fields": fields]]]]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Data(("<script>window['__ICE_SUSPENSE_LOADER__']['undefined'] = \n" + String(decoding: bytes, as: UTF8.self) + ";</script>").utf8)
    }
    private func parse(_ fields: [String: Any], key: String = "newLogistics") throws -> UAPITrackingResult {
        try TaobaoTrackingParser.parse(html(fields, key: key), trackingNumber: number, now: now)
    }
    private func assertError(_ expected: TaobaoTrackingError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? TaobaoTrackingError, expected, file: file, line: line)
        }
    }

    func testValidFieldsSurviveEmptyOtherEnvelopeAsInUpstreamSamples() throws {
        for (valid, placeholder) in [("newLogistics", "logisticsDetailH5"), ("logisticsDetailH5", "newLogistics")] {
            for empty in [NSNull(), [String: Any](), ["fields": NSNull()], ["fields": [String: Any]()]] as [Any] {
                let root: [String: Any] = ["result": ["data": [valid: ["fields": fields([node("01-02 10:00")])], placeholder: empty]]]
                let json = try JSONSerialization.data(withJSONObject: root)
                let bytes = Data(("['__ICE_SUSPENSE_LOADER__']['undefined'] = " + String(decoding: json, as: UTF8.self)).utf8)
                XCTAssertEqual(try TaobaoTrackingParser.parse(bytes, trackingNumber: number, now: now).trackingNumber, number)
            }
        }
    }
    func testAlternateTimeAndStringLabel() throws {
        var value = fields([])
        value["multiStage"] = [["time": "01-02 10:00", "title": "运输中", "labelDesc": "备用正文"]]
        XCTAssertTrue(try parse(value).logisticsInfo.contains("备用正文"))
    }
    func testStructuredResultSortedWithoutSavingHTMLOrCarrierCode() throws {
        let result = try parse(fields([node("01-01 10:00", "运输中", "较早"), node("01-02 10:00", "待取件", "最新")]))
        XCTAssertEqual(result.trackingNumber, number)
        XCTAssertEqual(result.carrierName, "顺丰")
        XCTAssertEqual(result.carrierCode, "")
        XCTAssertEqual(result.status, .readyForPickup)
        XCTAssertEqual(result.logisticsInfo, "待取件 最新")
        XCTAssertEqual(result.logisticsTime, ISO8601DateFormatter().date(from: "2026-01-02T10:00:00+08:00"))
        XCTAssertTrue(result.queryInfo.contains("原始：01-02 10:00"))
        XCTAssertTrue(result.queryInfo.contains("年份推断"))
        XCTAssertFalse(result.queryInfo.contains("<script>"))
        XCTAssertTrue(result.queryInfo.range(of: "最新")!.lowerBound < result.queryInfo.range(of: "较早")!.lowerBound)
    }
    func testLegacyStructuredPathAndFullTimestamp() throws {
        let result = try parse(fields([node("2025-12-31 23:59:01", "已签收")]), key: "logisticsDetailH5")
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(result.logisticsTime, ISO8601DateFormatter().date(from: "2025-12-31T23:59:01+08:00"))
        XCTAssertFalse(result.queryInfo.contains("年份推断"))
    }
    func testYearBoundaryAndSameMinuteNodesAreNotDropped() throws {
        let result = try parse(fields([node("12-31 23:59", "运输中", "去年"), node("01-01 00:01", "运输中", "甲"), node("01-01 00:01", "运输中", "乙")]))
        XCTAssertTrue(result.queryInfo.contains("2025-12-31 23:59"))
        XCTAssertTrue(result.queryInfo.contains("甲"))
        XCTAssertTrue(result.queryInfo.contains("乙"))
    }
    func testRichTextAndQuotedBracesAreParsedAsJSONNotScript() throws {
        var value = fields([])
        value["multiStage"] = [["subtitle": "01-02 10:00", "title": "运输中", "labelDesc": ["richContent": [["text": "含 } 和 \\\" 字符"], ["text": "下一段"]]]]]
        XCTAssertTrue(try parse(value).logisticsInfo.contains("下一段"))
    }
    func testUndatedDeliveryAddressCardExcluded() throws {
        var value = fields([node("01-02 10:00")])
        var nodes = value["multiStage"] as! [[String: Any]]
        nodes.insert(["title": "送至", "labelDesc": ["text": "姓名手机号完整地址不应保存"]], at: 0)
        value["multiStage"] = nodes
        XCTAssertFalse(try parse(value).queryInfo.contains("完整地址"))
    }
    func testUnknownTitleNeverUsesDoingOrDoneToInferStatus() throws {
        var value = fields([])
        value["multiStage"] = [["subtitle": "01-02 10:00", "title": "未知阶段", "status": "done", "type": "doing", "text": "节点"]]
        XCTAssertNil(try parse(value).status)
    }
    func testExplicitStatusMapping() throws {
        let cases: [(String, ShipmentStatus)] = [("运输中", .inTransit), ("已揽收", .inTransit), ("派送中", .outForDelivery), ("待领取", .readyForPickup), ("已签收", .delivered), ("物流异常", .exception)]
        for (title, expected) in cases { XCTAssertEqual(try parse(fields([node("01-02 10:00", title)])).status, expected) }
    }
    func testExactIdentityMissingMaskedMismatchAndConflictingNumbersRejected() {
        for candidate in ["", "SF123****90123", "SF9999999999999", "sf1234567890123"] {
            var value = fields([node("01-02 10:00")]); value["mailNo"] = candidate
            value["logisticCompany"] = ["mailNo": candidate]
            assertError(.identityMismatch) { _ = try self.parse(value) }
        }
        var conflicting = fields([node("01-02 10:00")]); conflicting["mailNo"] = "SF9999999999999"
        assertError(.identityMismatch) { _ = try self.parse(conflicting) }
        var missing = fields([node("01-02 10:00")]); missing.removeValue(forKey: "mailNo"); missing.removeValue(forKey: "logisticCompany")
        assertError(.identityMismatch) { _ = try self.parse(missing) }
    }
    func testUnknownMultiPackageShapeAndDualFieldEnvelopesRejected() throws {
        let bytes = try html(["packages": [fields([node("01-02 10:00")])]])
        assertError(.unsupported) { _ = try TaobaoTrackingParser.parse(bytes, trackingNumber: self.number, now: self.now) }
        let object: [String: Any] = ["result": ["data": ["newLogistics": ["fields": fields([node("01-02 10:00")])], "logisticsDetailH5": ["fields": fields([node("01-02 10:00")])]]]]
        let json = try JSONSerialization.data(withJSONObject: object)
        let ambiguous = Data(("['__ICE_SUSPENSE_LOADER__']['undefined'] = " + String(decoding: json, as: UTF8.self)).utf8)
        assertError(.unsupported) { _ = try TaobaoTrackingParser.parse(ambiguous, trackingNumber: self.number, now: self.now) }
    }
    func testEmptyAndUndatedOnlyTraceFailRatherThanEraseOldData() {
        assertError(.noTrace) { _ = try self.parse(self.fields([])) }
        assertError(.noTrace) { _ = try self.parse(self.fields([["title": "送至", "text": "收件地址"]])) }
    }
    func testStrictInvalidDatesNeverNormalizeOrInventTimes() {
        for raw in ["02-30 10:00", "01-02 25:00", "2025-02-29 12:00", "昨天 10:00", "2026-01-02 10:00 junk"] {
            assertError(.unsupported) { _ = try self.parse(self.fields([self.node(raw)])) }
        }
    }
    func testPageWithoutMarkerIsUnsupportedNotAssumedAuthentication() {
        assertError(.unsupported) { _ = try TaobaoTrackingParser.parse(Data("<html>登录</html>".utf8), trackingNumber: self.number, now: self.now) }
        assertError(.unsupported) { _ = try TaobaoTrackingParser.parse(Data("['__ICE_SUSPENSE_LOADER__']['undefined'] = {\"result\":\"JUMP_302\"}".utf8), trackingNumber: self.number, now: self.now) }
    }
    func testExplicitAuthenticationAndVerificationCodesStopOnlyTaobaoBatch() throws {
        for (ret, expected) in [("FAIL_SYS_SESSION_EXPIRED", TaobaoTrackingError.authentication), ("FAIL_SYS_USER_VALIDATE", .verification)] {
            let json = try JSONSerialization.data(withJSONObject: ["ret": [ret]])
            let bytes = Data(("['__ICE_SUSPENSE_LOADER__']['undefined'] = " + String(decoding: json, as: UTF8.self)).utf8)
            assertError(expected) { _ = try TaobaoTrackingParser.parse(bytes, trackingNumber: self.number, now: self.now) }
            XCTAssertTrue(expected.stopsBatch)
        }
        for error in [TaobaoTrackingError.missingBinding, .unsupported, .identityMismatch, .noTrace] { XCTAssertFalse(error.stopsBatch) }
    }
    func testOversizeTooDeepTruncatedAndDuplicateMarkersFailClosed() throws {
        let marker = "['__ICE_SUSPENSE_LOADER__']['undefined'] = "
        let valid = try html(fields([node("01-02 10:00")]))
        let inputs = [Data(repeating: 32, count: 2_000_001), Data((marker + String(repeating: "{\"x\":", count: 40) + "{}" + String(repeating: "}", count: 40)).utf8), Data((marker + "{\"broken\":").utf8), valid + valid]
        for bytes in inputs { assertError(.unsupported) { _ = try TaobaoTrackingParser.parse(bytes, trackingNumber: self.number, now: self.now) } }
    }

    final class Keys: AIKeyStore {
        var value: String?
        func read() throws -> String? { value }
        func save(_ key: String) throws { value = key }
        func delete() throws { value = nil }
        func read(endpoint: String) throws -> String? { value }
        func save(_ key: String, endpoint: String) throws { value = key }
        func delete(endpoint: String) throws { value = nil }
    }
    final class Network: AINetworking {
        var requests: [URLRequest] = []
        var bytes = Data()
        var status = 200
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            return (bytes, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func client(_ network: Network) throws -> TaobaoTrackingClient {
        let session = TaobaoTrialSession(keys: Keys())
        try session.save([
            .init(name: "fixture", value: "private-value", domain: ".taobao.com", path: "/", secure: true, expires: nil),
            .init(name: "wrong", value: "not-sent", domain: ".evil.test", path: "/", secure: true, expires: nil),
            .init(name: "otherPath", value: "not-sent", domain: ".taobao.com", path: "/h5/", secure: true, expires: nil)
        ])
        return TaobaoTrackingClient(network: network, session: session)
    }
    func testClientUsesOneFixedGETWithScopedCookiesAndNoSecretsInResult() async throws {
        let network = Network(); network.bytes = try html(fields([node("2025-12-31 10:00")]))
        let result = try await client(network).query(orderID: "1234567890123456", trackingNumber: number)
        XCTAssertEqual(network.requests.count, 1)
        let request = try XCTUnwrap(network.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mobile Safari") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        XCTAssertEqual(request.url?.host, "pages-g.m.taobao.com")
        XCTAssertEqual(request.url?.path, "/wow/z/app/mtb/logisticsV2/h5-detail")
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "x-ssr", value: "true"), URLQueryItem(name: "bizOrderId", value: "1234567890123456")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "fixture=private-value")
        XCTAssertFalse(result.queryInfo.contains("private-value"))
        XCTAssertFalse(result.queryInfo.contains("1234567890123456"))
    }
    func testInvalidBindingNeverDispatchesOrRepairsIdentifier() async throws {
        let network = Network(); let client = try client(network)
        for order in ["", " 12345678", "12345678\n", "12345", "123456&x=1", "１２３４５６７８"] {
            do { _ = try await client.query(orderID: order, trackingNumber: number); XCTFail() }
            catch { XCTAssertEqual(error as? TaobaoTrackingError, .missingBinding) }
        }
        do { _ = try await client.query(orderID: "12345678", trackingNumber: "SF12***"); XCTFail() }
        catch { XCTAssertEqual(error as? TaobaoTrackingError, .identityMismatch) }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testMissingSessionAndHTTPFailuresAreSanitizedAndNeverRetried() async throws {
        let network = Network()
        do { _ = try await TaobaoTrackingClient(network: network, session: TaobaoTrialSession(keys: Keys())).query(orderID: "12345678", trackingNumber: number); XCTFail() }
        catch { XCTAssertEqual(error as? TaobaoTrackingError, .authentication) }
        XCTAssertTrue(network.requests.isEmpty)
        let client = try client(network)
        for (status, expected) in [(302, TaobaoTrackingError.unsupported), (401, .authentication), (403, .verification), (500, .unsupported)] {
            network.status = status
            do { _ = try await client.query(orderID: "12345678", trackingNumber: number); XCTFail() }
            catch { XCTAssertEqual(error as? TaobaoTrackingError, expected) }
        }
        XCTAssertEqual(network.requests.count, 4)
    }
    func testShipmentOldJSONAndNewFieldsRoundTrip() throws {
        let old = Shipment(trackingNumber: number, carrierName: "顺丰", carrierCode: "SF")
        let oldJSON = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(Shipment.self, from: oldJSON)
        XCTAssertNil(decoded.originPlatform); XCTAssertNil(decoded.refreshChannel)
        XCTAssertNil(decoded.taobaoOrderID); XCTAssertNil(decoded.logisticsSource); XCTAssertNil(decoded.lastRefreshError)
        var bound = decoded
        bound.originPlatform = "taobao"; bound.refreshChannel = "uapi"; bound.taobaoOrderID = "12345678"
        bound.logisticsSource = "taobao"; bound.lastRefreshError = "上次未成功"
        XCTAssertEqual(try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(bound)), bound)
        XCTAssertEqual(bound.id, old.id)
    }
}
