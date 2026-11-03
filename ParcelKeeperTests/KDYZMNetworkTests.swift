import XCTest
@testable import ParcelKeeper

final class KDYZMNetworkTests: XCTestCase {
    final class Transport: KDYZMTransport {
        var requests: [URLRequest] = []
        var responses: [(Data, Int)] = []
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            guard !responses.isEmpty else { throw KDYZMError.network }
            return responses.removeFirst()
        }
    }
    final class Keys: KDYZMCredentialStore {
        var value: KDYZMCredential?
        func read() throws -> KDYZMCredential? { value }
        func save(_ value: KDYZMCredential) throws { self.value = value }
        func clear() throws { value = nil }
    }
    struct Empty: Decodable {}
    let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())

    func testRemainingTimeoutIsPassedAndExpiredBudgetDoesNotSend() async throws {
        let t = Transport(); t.responses = [(Data("{}".utf8), 200)]
        let client = KDYZMClient(transport: t)
        _ = try await client.request(Empty.self, origin: credential.baseURL, path: "/v1/snapshot", credential: credential, timeout: 0.25)
        XCTAssertEqual(t.requests[0].timeoutInterval, 0.25, accuracy: 0.001)
        do {
            _ = try await client.request(Empty.self, origin: credential.baseURL, path: "/v1/snapshot", credential: credential, timeout: 0)
            XCTFail("expired budget must not send")
        } catch { XCTAssertEqual(error as? KDYZMError, .queued) }
        XCTAssertEqual(t.requests.count, 1)
    }
    func testTokenNeverSentToDifferentOrigin() async throws {
        let transport = Transport()
        do {
            _ = try await KDYZMClient(transport: transport).request(Empty.self, origin: "https://other.example", path: "/v1/snapshot", credential: credential)
            XCTFail("must reject before transport")
        } catch { XCTAssertEqual(error as? KDYZMError, .stale) }
        XCTAssertTrue(transport.requests.isEmpty)
    }
    func testErrorsAreWhitelistedAndOversizeIsRejected() async throws {
        let t = Transport()
        t.responses = [(Data(#"{"error":{"code":"DEVICE_UNAUTHORIZED","message":"pcd_SECRET raw upstream"}}"#.utf8), 401), (Data(repeating: 32, count: 2_000_001), 200)]
        let client = KDYZMClient(transport: t)
        do { _ = try await client.request(Empty.self, origin: credential.baseURL, path: "/v1/snapshot", credential: credential); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .unauthorized); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        do { _ = try await client.request(Empty.self, origin: credential.baseURL, path: "/v1/snapshot", credential: credential); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .invalid) }
        XCTAssertEqual(t.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer pcd_TEST_ONLY")
    }
    func testRedirectDelegateRejectsEvenSameOrigin() {
        let url = URL(string: credential.baseURL + "/v1/snapshot")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": credential.baseURL + "/other"])!
        var called = false
        KDYZMHTTPS().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) { request in
            called = true; XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
    func testGenerationRejectsRetiredCredentialAndNoWriteRuns() async throws {
        let keys = Keys(); keys.value = credential
        let connection = KDYZMConnection(keys: keys)
        keys.value?.generation = UUID()
        var wrote = false
        do { try await connection.commit(credential) { wrote = true }; XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .stale) }
        XCTAssertFalse(wrote)
    }
    func testUnbindFailureKeepsCredentialAndSuccessNeedsReadback() async throws {
        let keys = Keys(); keys.value = credential
        let t = Transport()
        let connection = KDYZMConnection(keys: keys, client: KDYZMClient(transport: t))
        t.responses = [(Data(#"{"revoked":true}"#.utf8), 200), (Data("{}".utf8), 500)]
        do { try await connection.unbind(); XCTFail() } catch {}
        XCTAssertEqual(keys.value, credential)
        t.responses = [(Data(#"{"revoked":true}"#.utf8), 200), (Data(#"{"error":{"code":"DEVICE_UNAUTHORIZED"}}"#.utf8), 401)]
        try await connection.unbind()
        XCTAssertNil(keys.value)
        XCTAssertEqual(t.requests.map(\.httpMethod), ["DELETE", "GET", "DELETE", "GET"])
    }
    func testFailedEmptyAndOlderLogisticsPreserveEverything() throws {
        var local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd", logisticsInfo: "旧轨迹", logisticsTime: Date(timeIntervalSince1970: 200), queryInfo: "旧完整轨迹", lastQueriedAt: Date(timeIntervalSince1970: 200))
        let original = local
        var remote = KDYZMRemoteShipment(id: "s", orderId: "o", accountId: "a", waybillNo: local.trackingNumber, carrier: local.carrierName, status: "transit", logisticsEvents: [.init(time: 100_000, timeText: "", description: "过早轨迹", location: "")], logisticsState: "error", logisticsUpdatedAt: 100_000)
        XCTAssertFalse(try KDYZMMerger.update(remote, local: &local, refresh: true))
        XCTAssertEqual(local, original)
        remote.logisticsState = "ok"
        XCTAssertFalse(try KDYZMMerger.update(remote, local: &local, refresh: true))
        XCTAssertEqual(local, original)
        remote.logisticsEvents = []
        XCTAssertFalse(try KDYZMMerger.update(remote, local: &local, refresh: true))
        XCTAssertEqual(local, original)
    }
    func testOptionalBindingOldJSONAndBackupRoundTrip() throws {
        let old = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd")
        let decoded = try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.backendBinding)
        var new = old
        new.backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
        XCTAssertEqual(try JSONDecoder().decode(Shipment.self, from: JSONEncoder().encode(new)), new)
    }
}
