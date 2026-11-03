import XCTest
@testable import ParcelKeeper

// Offline protocol fixtures follow DSH 585111e14563a35ea62fb062aad9b0675739c79b.
final class MallDirectClientTests: XCTestCase {
    private func cookies(_ platform: MallPlatform) -> [TaobaoTrialCookie] {
        let names = ["PDDAccessToken", "pdd_user_id"]
        return names.map { .init(name: $0, value: "fixture", domain: ".yangkeduo.com", path: "/", secure: true, expires: nil) }
    }
    private func json(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func html(_ value: [String: Any]) -> Data { Data(("<script>window.rawData = " + String(data: json(value), encoding: .utf8)! + ";</script>").utf8) }
    private func pddList(signed: Bool = false) -> [String: Any] {
        ["ordersStore": ["orders": [["orderSn": "261021-009237962271222", "trackingNumber": "77127094235378", "shippingId": 371, "orderStatusPrompt": signed ? "交易成功" : "待收货", "orderGoods": [["goodsName": "含 } 与 \" 引号"]]]]]]
    }
    private func pddShip(number: String = "77127094235378", status: String = "UNKNOWN", traces: [[String: Any]]? = nil) -> [String: Any] {
        ["store": ["traceData": ["shipping": ["trackingNumber": number, "shippingName": "中通国际", "shippingStatus": status, "traces": traces ?? [["info": "预计明天派送，未签收", "displayTime": "2026-10-22 22:29:23"]]]]]]
    }
    private func failure(_ reason: MallWebError, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure") }
        catch let error as MallDirectError { XCTAssertEqual(error.reason, reason); XCTAssertFalse(error.localizedDescription.contains("fixture")) }
        catch { XCTFail("Unsafe/unexpected error type: \(type(of: error))") }
    }
    func testPDDLatestPickupCompletionUpdatesStatusWithoutScanningHistory() async throws {
        for (latest, expected) in [("快件已按约定投递，取件人凭取件码完成取件", ShipmentStatus.delivered), ("您的快件已妥投，已在代收点取出", .delivered), ("已放入快递柜，等待取件", .readyForPickup)] {
            let traces: [[String: Any]] = [["info": "正在派送", "time": 1792679300], ["info": latest, "time": 1792679363]]
            let network = MallDirectFixtureNetwork([html(pddList()), html(pddShip(traces: traces))])
            let result = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: network).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378")
            XCTAssertEqual(result.status, expected)
        }
    }
    func testPDDPublicQueryAndSignedOrderCanRefresh() async throws {
        let network = MallDirectFixtureNetwork([html(pddList(signed: true)), html(pddShip(status: "SIGNED"))])
        let result = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: network).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378")
        XCTAssertEqual(result.status, .delivered)
        XCTAssertEqual(result.carrierName, "中通国际")
        let list = URLComponents(url: network.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(list.map(\.name)), Set(["type", "comment_tab", "combine_orders", "main_orders"]))
        XCTAssertEqual(list.first { $0.name == "type" }?.value, "0")
        let trace = URLComponents(url: network.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(trace.first { $0.name == "shipping_id" }?.value, "371")
        XCTAssertEqual(trace.first { $0.name == "hide_address" }?.value, "1")
        XCTAssertEqual(trace.first { $0.name == "order_sn" }?.value, "261021-009237962271222")
        XCTAssertEqual(trace.first { $0.name == "tracking_number" }?.value, "77127094235378")
        XCTAssertTrue(network.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testPDDScannerQuotesAndSignedFiltering() async throws {
        let network = MallDirectFixtureNetwork([html(pddList()), html(pddShip())])
        let result = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: network).fetchOrders()
        XCTAssertEqual(result.first?.title, "含 } 与 \" 引号")
        let signed = MallDirectFixtureNetwork([html(pddList(signed: true))])
        let empty = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: signed).fetchOrders()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(signed.requests.count, 1)
    }
    func testStrictAssignmentUnknownStructuresAndEmptyTrace() async {
        for data in [Data("window.rawData.foo = {};".utf8), Data("window.rawData == {};".utf8), Data("window.rawData = {\"a\":1".utf8), html(["other": []])] {
            await failure(.unsupported) { try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([data])).verifySession() }
        }
        await failure(.noTrace) { _ = try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([self.html(self.pddList()), self.html(self.pddShip(traces: []))])).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378") }
    }
    func testCookieIsolationAndHeaderInjection() async throws {
        let foreign = TaobaoTrialCookie(name: "foreign", value: "secret", domain: ".jd.com", path: "/", secure: true, expires: nil)
        let hostOnly = TaobaoTrialCookie(name: "hostOnly", value: "secret", domain: "yangkeduo.com", path: "/", secure: true, expires: nil)
        let scoped = TaobaoTrialCookie(name: "scoped", value: "secret", domain: ".yangkeduo.com", path: "/other", secure: true, expires: nil)
        let expired = TaobaoTrialCookie(name: "expired", value: "secret", domain: ".yangkeduo.com", path: "/", secure: true, expires: .distantPast)
        let network = MallDirectFixtureNetwork([html(["ordersStore": ["orders": []]])])
        try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd) + [foreign, hostOnly, scoped, expired], network: network).verifySession()
        XCTAssertEqual(network.requests.first?.value(forHTTPHeaderField: "Cookie"), "PDDAccessToken=fixture; pdd_user_id=fixture")
        let bad = TaobaoTrialCookie(name: "PDDAccessToken", value: "secret\r\nX-Evil: yes", domain: ".yangkeduo.com", path: "/", secure: true, expires: nil)
        let blocked = MallDirectFixtureNetwork([])
        await failure(.authentication) { try await MallDirectClient(platform: .pdd, cookies: [bad] + self.cookies(.pdd), network: blocked).verifySession() }
        XCTAssertTrue(blocked.requests.isEmpty)
    }
    func testMissingCredentialsAuthVerificationRedirectAndSizeAreSafe() async {
        let noCredentials = MallDirectFixtureNetwork([])
        await failure(.authentication) { try await MallDirectClient(platform: .pdd, cookies: [], network: noCredentials).verifySession() }
        XCTAssertTrue(noCredentials.requests.isEmpty)
        for (status, reason) in [(401, MallWebError.authentication), (403, .verification), (302, .authentication), (429, .verification)] {
            let network = MallDirectFixtureNetwork([Data("secret raw server body".utf8)], status: status)
            await failure(reason) { try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: network).verifySession() }
            XCTAssertEqual(network.requests.count, 1)
        }
        await failure(.unsupported) { try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([Data(repeating: 65, count: 2_000_001)])).verifySession() }
        await failure(.authentication) { try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([self.html(["code": "1001", "echo": "private-secret"])] )).verifySession() }
    }
    func testEpochTimeAndNoTraceCandidateRemainDistinctFromSuccessfulSync() async throws {
        let traces: [[String: Any]] = [["info": "运输中", "displayTime": "10-22 22:29", "time": 1792679363000]]
        let network = MallDirectFixtureNetwork([html(pddList()), html(pddShip(traces: traces))])
        let result = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: network).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378")
        XCTAssertEqual(result.logisticsTime?.timeIntervalSince1970, 1792679363)
        XCTAssertEqual(result.status, .inTransit)
        let tooMany = Array(repeating: ["info": "运输中", "time": 1792679363] as [String: Any], count: 501)
        await failure(.unsupported) { _ = try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([self.html(self.pddList()), self.html(self.pddShip(traces: tooMany))])).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378") }
    }
    func testPDDNoTraceCandidateIsNotSuccessfulTrackingAndCancellationNeverDispatches() async throws {
        let network = MallDirectFixtureNetwork([html(pddList()), html(pddShip(traces: []))])
        let candidates = try await MallDirectClient(platform: .pdd, cookies: cookies(.pdd), network: network).fetchOrders()
        XCTAssertEqual(candidates.first?.trackingNumber, "77127094235378")
        let blocked = MallDirectFixtureNetwork([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: blocked).verifySession()
        }
        do { try await task.value; XCTFail("Cancelled operation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(blocked.requests.isEmpty)
    }
    func testMissingShippingIDDoesNotIssueDetailRequest() async {
        var fixture = pddList()
        var store = fixture["ordersStore"] as! [String: Any]
        var list = store["orders"] as! [[String: Any]]
        list[0].removeValue(forKey: "shippingId")
        store["orders"] = list
        fixture["ordersStore"] = store
        let network = MallDirectFixtureNetwork([html(fixture)])
        await failure(.noTrace) { _ = try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: network).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378") }
        XCTAssertEqual(network.requests.count, 1)
        let safe = MallDirectError(reason: .unsupported, stage: "pdd-trace", http: 200, bytes: 12, code: "secret-code")
        XCTAssertNil(safe.code)
        XCTAssertFalse(safe.localizedDescription.contains("secret-code"))
    }
    func testPDDBindingMismatchAndMissingShippingIDDoNotGuess() async {
        await failure(.identityMismatch) { _ = try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: MallDirectFixtureNetwork([self.html(self.pddList()), self.html(self.pddShip(number: "OTHER123456"))])).query(orderID: "261021-009237962271222", trackingNumber: "77127094235378") }
        let network = MallDirectFixtureNetwork([html(pddList())])
        await failure(.noTrace) { _ = try await MallDirectClient(platform: .pdd, cookies: self.cookies(.pdd), network: network).query(orderID: "261021-009237962271222", trackingNumber: "OTHER123456") }
        XCTAssertEqual(network.requests.count, 1)
    }
}

private final class MallDirectFixtureNetwork: AINetworking {
    var requests: [URLRequest] = []
    var responses: [Data]
    let status: Int
    init(_ responses: [Data], status: Int = 200) { self.responses = responses; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return (responses.removeFirst(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
