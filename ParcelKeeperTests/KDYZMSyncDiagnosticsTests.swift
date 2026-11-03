import XCTest
@testable import ParcelKeeper

final class KDYZMSyncDiagnosticsTests: XCTestCase {
    private func fixture() -> KDYZMSnapshot {
        KDYZMSnapshot(schemaVersion: 1, serverRevision: 1, accounts: [],
            orders: [
                .init(id: "o1", accountId: "a", platform: "taobao", platformOrderId: "p1", familyId: "f"),
                .init(id: "o2", accountId: "a", platform: "taobao", platformOrderId: "p2", familyId: "f")],
            shipments: [
                .init(id: "s1", orderId: "o1", accountId: "a", familyId: "f", waybillNo: "YT1234567890123", carrier: "圆通", status: "transit"),
                .init(id: "s2", orderId: "o2", accountId: "a", familyId: "f", waybillNo: "YT1234567890123", carrier: "圆通", status: "transit")],
            hiddenIds: [], deletedIds: [], familyIds: ["f"], legacyAccountIds: [], families: [])
    }
    func testCombinedShippingAcrossOrdersValidatesAndImportsIdempotently() throws {
        let snapshot = fixture()
        XCTAssertNoThrow(try snapshot.validated())
        let group = PickupGroup(name: "快递", sortOrder: 0)
        var data = PickupDataset(groups: [group], records: [], shipments: [], expressGroupID: group.id)
        XCTAssertEqual(try KDYZMMerger.apply(snapshot, origin: "https://example.com", to: &data).imported, 2)
        let ids = data.shipments.map(\.id)
        XCTAssertEqual(Set(data.shipments.compactMap(\.backendBinding)).count, 2)
        XCTAssertEqual(try KDYZMMerger.apply(snapshot, origin: "https://example.com", to: &data).imported, 0)
        XCTAssertEqual(data.shipments.map(\.id), ids)
    }
    func testDuplicateWithinOrderAndUnauthorizedStillReject() throws {
        var snapshot = fixture()
        snapshot.shipments[1].orderId = "o1"
        XCTAssertThrowsError(try snapshot.validated())
        snapshot = fixture(); snapshot.familyIds = []
        XCTAssertThrowsError(try snapshot.validated()) { XCTAssertEqual($0 as? KDYZMError, .forbidden) }
        snapshot = fixture(); snapshot.shipments[1].id = "s1"
        XCTAssertThrowsError(try snapshot.validated())
    }
    func testSnapshotDecodingValidationAndAuthorizationStayDistinct() async throws {
        let transport = KDYZMNetworkTests.Transport()
        let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
        transport.responses = [(Data(#"{"schemaVersion":"PRIVATE_RAW"}"#.utf8), 200)]
        let client = KDYZMClient(transport: transport)
        do { _ = try await client.snapshot(credential); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMSyncFailure, .decoding); XCTAssertFalse(KDYZMError.safe(error).contains("PRIVATE_RAW")) }
        let invalid: [String: Any] = ["schemaVersion": 2, "serverRevision": 1, "accounts": [], "orders": [], "shipments": [], "hiddenIds": [], "deletedIds": []]
        transport.responses = [(try JSONSerialization.data(withJSONObject: invalid), 200)]
        do { _ = try await client.snapshot(credential); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMSyncFailure, .validation) }
        transport.responses = [(Data(#"{"error":{"code":"DEVICE_UNAUTHORIZED","message":"PRIVATE_RAW"}}"#.utf8), 401)]
        do { _ = try await client.snapshot(credential); XCTFail() }
        catch { XCTAssertEqual(error as? KDYZMError, .unauthorized) }
    }
    func testDiagnosticsAreFixedSafeStageCodes() {
        let codes = ["SYNC-DECODE", "SYNC-VALIDATE", "SYNC-LINK", "SYNC-READ", "SYNC-WRITE", "SYNC-DISPLAY"]
        XCTAssertEqual(KDYZMSyncFailure.allCases.count, codes.count)
        for (failure, code) in zip(KDYZMSyncFailure.allCases, codes) {
            XCTAssertTrue(KDYZMError.safe(failure).contains(code))
            XCTAssertFalse(KDYZMError.safe(failure).contains("https://"))
        }
    }
}
