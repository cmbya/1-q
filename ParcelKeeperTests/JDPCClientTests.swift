import XCTest
@testable import ParcelKeeper

final class JDPCClientTests: XCTestCase {
    private let order = "123456789012"
    private func cookies() throws -> [TaobaoTrialCookie] { try MallCookieImport.parse("thor=SYNTHETIC", platform: .jd) }
    private func list() -> [String: Any] {
        ["success": true, "data": ["totalNum": 1, "orderList": [["orderId": order, "dateSubmit": "2026-10-15 12:00:00", "statusInfo": ["orderStateName": "待收货"], "wareList": [["name": "合成商品"]]]]]]
    }
    private func parcel(_ number: String, text: String = "运输中") -> [String: Any] {
        ["carriageInfo": ["carriageId": number, "carrier": "京东快递"], "trackGroupInfo": ["orderTrackShowList": [["CreationTime": "2026-11-01 10:00:00", "StatusName": text, "Content": "合成节点"]]]]
    }
    private var now: Date { JDOrderImportPolicy.submittedDate("2026-11-04 12:00:00")! }
    private func shopping(_ id: String, date: Any = "2026-10-15 12:00:00", status: String = "已签收", type: Int = 0) -> [String: Any] {
        ["orderId": id, "dateSubmit": date, "orderType": type, "statusInfo": ["orderStateName": status], "wareList": [["name": "配送字样的购物商品"]]]
    }
    private func page(_ rows: [[String: Any]], total: Int? = nil) -> [String: Any] {
        var data: [String: Any] = ["orderList": rows]
        if let total { data["totalNum"] = total }
        return ["success": true, "data": data]
    }
    func testTwentyTakeawaysDoNotHideOctober15CompletedShoppingOnSecondPage() async throws {
        let takeaway = (0..<20).map { shopping(String(123456789100 + $0), status: "外卖 已完成") }
        let network = JDPCFixtureNetwork([page(takeaway, total: 21), page([shopping(order)], total: 21), ["multiPackageTrackInfoList": [parcel("JD123456789")]]])
        let report = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrderReport()
        XCTAssertEqual(report.scanned, 21); XCTAssertEqual(report.excluded, 20)
        XCTAssertEqual(report.eligible, 1); XCTAssertEqual(report.candidates.count, 1); XCTAssertFalse(report.limited)
        XCTAssertEqual(network.requests.count, 3)
        let body = String(data: network.requests[1].httpBody!, encoding: .utf8)!
        let raw = URLComponents(string: "https://example.test/?" + body)!.queryItems!.first!.value!
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Int])?["page"], 2)
    }
    func testMissingDateOutsideExcludedAndNoWaybillAreSeparateOrders() async throws {
        let network = JDPCFixtureNetwork([page([shopping(order), shopping("123456789013", date: ""), shopping("123456789014", date: "2026-10-05"), shopping("123456789015", type: 4)], total: 4), ["multiPackageTrackInfoList": []]])
        let report = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrderReport()
        XCTAssertEqual(report.scanned, 4); XCTAssertEqual(report.eligible, 1)
        XCTAssertEqual(report.missingDate, 1); XCTAssertEqual(report.outsideWindow, 1); XCTAssertEqual(report.excluded, 1)
        XCTAssertEqual(report.withoutWaybill, 1); XCTAssertTrue(report.candidates.isEmpty); XCTAssertFalse(report.limited)
        XCTAssertEqual(network.requests.count, 2)
    }
    func testRepeatedPageStopsLimitedAndExplicitEmptyStopsComplete() async throws {
        for repeated in [true, false] {
            let rows = [shopping(order, type: 4)]
            let network = JDPCFixtureNetwork([page(rows), page(repeated ? rows : [])])
            let report = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrderReport()
            XCTAssertEqual(report.scanned, 1); XCTAssertEqual(report.limited, repeated)
            XCTAssertEqual(network.requests.count, 2)
        }
    }
    func testTenPageAndTwentyDetailCapsAreExplicitNotSilentEight() async throws {
        let pages = (0..<10).map { page([shopping(String(123456789100 + $0), type: 4)]) }
        let capped = try await JDPCClient(cookies: cookies(), network: JDPCFixtureNetwork(pages), now: { self.now }).fetchOrderReport()
        XCTAssertTrue(capped.limited); XCTAssertEqual(capped.scanned, 10)
        let rows = (0..<21).map { shopping(String(123456789100 + $0)) }
        let network = JDPCFixtureNetwork([page(rows, total: 21)] + Array(repeating: ["multiPackageTrackInfoList": []], count: 20))
        let report = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrderReport()
        XCTAssertTrue(report.limited); XCTAssertEqual(report.eligible, 21); XCTAssertEqual(report.withoutWaybill, 20)
        XCTAssertEqual(network.requests.count, 21)
    }
    func testTimeoutAfterAcceptedListReturnsPartialWithoutInventingNoWaybill() async throws {
        let network = JDPCFixtureNetwork([page([shopping(order)], total: 1)], exhaustedError: URLError(.timedOut))
        let report = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrderReport()
        XCTAssertTrue(report.limited); XCTAssertEqual(report.eligible, 1); XCTAssertEqual(report.withoutWaybill, 0)
        XCTAssertTrue(report.candidates.isEmpty); XCTAssertEqual(network.requests.count, 2)
    }
    func testVerificationDoesNotRequireOrFilterMissingDate() async throws {
        let network = JDPCFixtureNetwork([page([shopping(order, date: "")], total: 1)])
        _ = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).verifySession()
        XCTAssertEqual(network.requests.count, 1)
    }
    func testCookieClientBuildsUnsignedListAndDetailAndKeepsSplitIdentity() async throws {
        let network = JDPCFixtureNetwork([list(), ["multiPackageTrackInfoList": [parcel("JD123456789"), parcel("SF123456789")]]])
        let values = try await JDPCClient(cookies: cookies(), network: network, now: { self.now }).fetchOrders()
        XCTAssertEqual(values.map(\.trackingNumber), ["JD123456789", "SF123456789"])
        XCTAssertEqual(Set(values.map(\.orderID)), Set([order]))
        XCTAssertEqual(network.requests.count, 2)
        for request in network.requests {
            XCTAssertEqual(request.url?.host, "api.m.jd.com")
            XCTAssertEqual(request.url?.path, "/api")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "thor=SYNTHETIC")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "loginType" }?.value, "3")
            XCTAssertFalse(items.contains { ["h5st", "uuid", "PassKey"].contains($0.name) })
        }
        let listBody = String(data: network.requests[0].httpBody!, encoding: .utf8)!
        let encoded = URLComponents(string: "https://example.test/?" + listBody)!.queryItems!.first!.value!
        let input = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String: Int]
        XCTAssertEqual(input, ["page": 1, "d": 1, "s": 4096])
    }
    func testSingleQueryUsesOnlyRequestedOrderAndFullWaybill() async throws {
        let network = JDPCFixtureNetwork([["multiPackageTrackInfoList": [parcel("JD123456789"), parcel("SF123456789", text: "本人已取件")]]])
        let value = try await JDPCClient(cookies: cookies(), network: network).query(orderID: order, trackingNumber: "SF123456789")
        XCTAssertEqual(value.trackingNumber, "SF123456789")
        XCTAssertEqual(value.status, .delivered)
        XCTAssertEqual(network.requests.count, 1)
        let items = URLComponents(url: network.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        let body = items.first { $0.name == "body" }!.value!
        let input = try JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: String]
        XCTAssertEqual(input, ["orderId": order])
        let mismatch = JDPCFixtureNetwork([["multiPackageTrackInfoList": [parcel("JD123456789")]]])
        do { _ = try await JDPCClient(cookies: cookies(), network: mismatch).query(orderID: order, trackingNumber: "SF123456789"); XCTFail() }
        catch let error as JDLoggedError { XCTAssertEqual(error.reason, .identity) }
    }
    func testEmptyUnknownExpiredAndBlockedAreDistinctAndSafe() async throws {
        try await JDPCClient(cookies: cookies(), network: JDPCFixtureNetwork([["success": true, "data": ["orderList": []]]])).verifySession()
        let cases: [([String: Any], Int, DiagnosticReason)] = [(["code": 3], 200, .authentication), ([:], 200, .parse), (["private": "SECRET"], 403, .verification), (["success": false, "message": "SECRET"], 200, .unsupported)]
        for (body, status, expected) in cases {
            let network = JDPCFixtureNetwork([body], status: status)
            do { try await JDPCClient(cookies: cookies(), network: network).verifySession(); XCTFail() }
            catch let error as JDLoggedError { XCTAssertEqual(error.reason, expected); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
            XCTAssertEqual(network.requests.count, 1)
        }
    }
    func testCredentialsDuplicatesAndWrongReturnedOrderCannotWrite() async throws {
        let empty = JDPCFixtureNetwork([])
        do { try await JDPCClient(cookies: [], network: empty).verifySession(); XCTFail() } catch { }
        XCTAssertTrue(empty.requests.isEmpty)
        let invalid: [[String: Any]] = [["orderId": "999999999999", "multiPackageTrackInfoList": [parcel("JD123456789")]], ["multiPackageTrackInfoList": [parcel("JD123456789"), parcel("JD123456789")]]]
        for data in invalid {
            do { _ = try await JDPCClient(cookies: cookies(), network: JDPCFixtureNetwork([data])).query(orderID: order, trackingNumber: "JD123456789"); XCTFail() }
            catch let error as JDLoggedError { XCTAssertEqual(error.reason, .identity) }
        }
    }
    func testCancellationBeforeDispatchDoesNotRequest() async throws {
        let network = JDPCFixtureNetwork([])
        let input = try cookies()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await JDPCClient(cookies: input, network: network).verifySession()
        }
        task.cancel()
        do { try await task.value; XCTFail() }
        catch is CancellationError { }
        XCTAssertTrue(network.requests.isEmpty)
    }
    func testVerificationReturnsResponseRotatedCookieWithoutSavingIt() async throws {
        let input = try cookies()
        let network = JDPCFixtureNetwork([list()], headers: ["Set-Cookie": "thor=ROTATED_SYNTHETIC; Domain=.jd.com; Path=/; Secure; HttpOnly"])
        let fresh = try await JDPCClient(cookies: input, network: network).verifySession()
        XCTAssertEqual(fresh.first { $0.name == "thor" }?.value, "ROTATED_SYNTHETIC")
        XCTAssertEqual(input.first?.value, "SYNTHETIC")
        XCTAssertEqual(network.requests.first?.value(forHTTPHeaderField: "Cookie"), "thor=SYNTHETIC")
    }
    func testPCParserSupportsNestedOrderCarriageInfoWithoutWholePageFallback() throws {
        let group: [String: Any] = ["orderCarriageInfo": ["carriageId": "JD123456789", "carrier": "京东快递"],
            "orderTrackShowList": [["CreationTime": "2026-11-01 10:00:00", "Content": "运输中"]]]
        let values = try JDPCParser.parcels(["multiPackageTrackInfoList": [["trackGroupInfo": group], ["trackGroupInfo": ["orderTrackShowList": []]]]], orderID: order)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.number, "JD123456789")
    }
    func testRedirectAndOversizeResponsesAreRejected() async throws {
        for network in [JDPCFixtureNetwork([list()], status: 302), JDPCFixtureNetwork([list()], otherURL: URL(string: "https://example.test")), JDPCFixtureNetwork([list()], oversized: true)] {
            do { try await JDPCClient(cookies: cookies(), network: network).verifySession(); XCTFail() }
            catch is JDLoggedError { }
            XCTAssertEqual(network.requests.count, 1)
        }
    }
}

private final class JDPCFixtureNetwork: AINetworking {
    var responses: [[String: Any]]
    var requests: [URLRequest] = []
    let status: Int
    let otherURL: URL?
    let oversized: Bool
    let headers: [String: String]?
    let exhaustedError: Error
    init(_ responses: [[String: Any]], status: Int = 200, otherURL: URL? = nil, oversized: Bool = false, headers: [String: String]? = nil, exhaustedError: Error = URLError(.badServerResponse)) {
        self.responses = responses; self.status = status; self.otherURL = otherURL; self.oversized = oversized; self.headers = headers; self.exhaustedError = exhaustedError
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw exhaustedError }
        let body = responses.removeFirst()
        let data: Data
        if oversized { data = Data(repeating: 65, count: 5 * 1024 * 1024 + 1) }
        else { data = try JSONSerialization.data(withJSONObject: body) }
        return (data, HTTPURLResponse(url: otherURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
