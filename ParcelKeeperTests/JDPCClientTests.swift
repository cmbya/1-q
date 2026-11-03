import XCTest
@testable import ParcelKeeper

final class JDPCClientTests: XCTestCase {
    private let order = "123456789012"
    private func cookies() throws -> [TaobaoTrialCookie] { try MallCookieImport.parse("thor=SYNTHETIC", platform: .jd) }
    private func list() -> [String: Any] {
        ["success": true, "data": ["orderList": [["orderId": order, "statusInfo": ["orderStateName": "待收货"], "wareList": [["name": "合成商品"]]]]]]
    }
    private func parcel(_ number: String, text: String = "运输中") -> [String: Any] {
        ["carriageInfo": ["carriageId": number, "carrier": "京东快递"], "trackGroupInfo": ["orderTrackShowList": [["CreationTime": "2026-11-01 10:00:00", "StatusName": text, "Content": "合成节点"]]]]
    }
    func testCookieClientBuildsUnsignedListAndDetailAndKeepsSplitIdentity() async throws {
        let network = JDPCFixtureNetwork([list(), ["multiPackageTrackInfoList": [parcel("JD123456789"), parcel("SF123456789")]]])
        let values = try await JDPCClient(cookies: cookies(), network: network).fetchOrders()
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
    init(_ responses: [[String: Any]], status: Int = 200, otherURL: URL? = nil, oversized: Bool = false, headers: [String: String]? = nil) {
        self.responses = responses; self.status = status; self.otherURL = otherURL; self.oversized = oversized; self.headers = headers
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        let body = responses.removeFirst()
        let data: Data
        if oversized { data = Data(repeating: 65, count: 5 * 1024 * 1024 + 1) }
        else { data = try JSONSerialization.data(withJSONObject: body) }
        return (data, HTTPURLResponse(url: otherURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
