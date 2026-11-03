import XCTest
@testable import ParcelKeeper

/// Real runtime regression tests; offline Python contracts do NOT execute these.
final class AuditMediumCoreTests: XCTestCase {
    final class Keys: AIKeyStore {
        var value: String?
        var accounts: [String: String] = [:]
        var failDelete = false
        var failSave = false
        func read() throws -> String? { value }
        func save(_ key: String) throws { if failSave { throw UAPIError.keychain }; value = key }
        func delete() throws { if failDelete { throw UAPIError.keychain }; value = nil }
        func read(endpoint: String) throws -> String? { accounts[endpoint] }
        func save(_ key: String, endpoint: String) throws { if failSave { throw UAPIError.keychain }; accounts[endpoint] = key }
        func delete(endpoint: String) throws { if failDelete { throw UAPIError.keychain }; accounts.removeValue(forKey: endpoint) }
    }
    final class Transport: KDYZMTransport {
        var bodies: [Data] = []
        var requests: [URLRequest] = []
        var onSnapshot: (() throws -> Void)?
        func send(_ request: URLRequest) async throws -> (Data, Int) {
            requests.append(request)
            if request.url?.path == "/v1/snapshot" { try onSnapshot?() }
            guard !bodies.isEmpty else { throw KDYZMError.network }
            return (bodies.removeFirst(), 200)
        }
    }
    var root: URL!
    var store: SharedPickupStore!
    var shipment: Shipment!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        shipment = Shipment(trackingNumber: "YT1234567890123", carrierName: "圆通", carrierCode: "yto", pickupCode: "42")
        try store.transaction { data in
            data.shipments.append(shipment)
            data.records.append(PickupRecord(groupID: try XCTUnwrap(data.expressGroupID), code: "42", isCompleted: true, shipmentID: shipment.id))
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRefreshPreservesManualCompletionIncludingConcurrentCompletion() async throws {
        for initiallyCompleted in [true, false] {
            try store.transaction { data in
                data.shipments[0].status = .inTransit
                data.shipments[0].lastQueriedAt = nil
                data.shipments[0].logisticsTime = nil
                data.records[0].isCompleted = initiallyCompleted
            }
            let client = TrackingRefreshTests.Client()
            client.result = UAPITrackingResult(trackingNumber: shipment.trackingNumber, carrierName: "圆通", carrierCode: "yuantong", status: .readyForPickup, logisticsInfo: "到站", logisticsTime: nil, queryInfo: "到站", queriedAt: Date())
            client.onQuery = { try self.store.transaction { $0.records[0].isCompleted = true } }
            var service = TrackingRefreshService(store: store, client: client, reloadWidgets: {})
            let phoneKeys = Keys(); let cacheKeys = Keys()
            service.phones = ShipmentPhoneStore(keys: phoneKeys, cache: PaidTrackingCache(directory: root.appendingPathComponent("refresh-cache"), phoneKeys: { _ in cacheKeys }))
            _ = try await service.refresh(id: shipment.id)
            XCTAssertTrue(try store.snapshot().records[0].isCompleted)
            XCTAssertEqual(try store.snapshot().shipments[0].status, .readyForPickup)
        }
    }
    func testShortcutNeverReopensButStillCompletesDelivered() throws {
        let service = ShipmentShortcutService(store: store, reloadWidgets: {})
        let input = ShipmentShortcutInput(trackingNumber: shipment.trackingNumber, carrierName: nil, logisticsInfo: nil, status: .readyForPickup, logisticsTime: nil)
        _ = try service.upsert(input, inferLogistics: false)
        XCTAssertTrue(try store.snapshot().records[0].isCompleted)
        try store.transaction { $0.records[0].isCompleted = false }
        var delivered = input; delivered.status = .delivered
        _ = try service.upsert(delivered, inferLogistics: false)
        XCTAssertTrue(try store.snapshot().records[0].isCompleted)
        // An explicitly reopened delivered record stays reopened on same-state updates.
        try store.transaction { $0.records[0].isCompleted = false }
        _ = try service.upsert(delivered, inferLogistics: false)
        XCTAssertFalse(try store.snapshot().records[0].isCompleted)
    }
    func testPhoneABAWithoutQueriesAndSameValueReuseAndClear() throws {
        let cacheKeys = Keys(); let phoneKeys = Keys()
        let cache = PaidTrackingCache(directory: root.appendingPathComponent("cache"), phoneKeys: { _ in cacheKeys })
        let phones = ShipmentPhoneStore(keys: phoneKeys, cache: cache)
        try phones.save("9276", for: shipment)
        let a = try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276")
        try phones.save("9276", for: shipment)
        XCTAssertEqual(a, try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276"))
        try phones.save("8351", for: shipment)
        try phones.save("9276", for: shipment) // no intervening cache.identity/query
        XCTAssertThrowsError(try cache.lookup(a))
        let again = try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276")
        XCTAssertNotEqual(a.phoneToken, again.phoneToken)
        try phones.clear(for: shipment)
        XCTAssertNil(cacheKeys.value)
        XCTAssertNil(try phones.read(for: shipment))
        XCTAssertThrowsError(try cache.lookup(again))
    }
    func testPhoneDeletionFailureFailsClosedAndRetirementRetriesBothSecrets() throws {
        let cacheKeys = Keys(); let phoneKeys = Keys()
        let cache = PaidTrackingCache(directory: root.appendingPathComponent("cache"), phoneKeys: { _ in cacheKeys })
        let phones = ShipmentPhoneStore(keys: phoneKeys, cache: cache)
        try phones.save("9276", for: shipment)
        let identity = try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276")
        cacheKeys.failDelete = true
        XCTAssertThrowsError(try phones.save("8351", for: shipment))
        XCTAssertEqual(try phones.read(for: shipment), "9276")
        var incoming = try store.snapshot()
        // Import merges: absence is not deletion. Replace the same tracking number
        // with a new identity so the original phone actually enters retirement.
        incoming.shipments[0].id = UUID()
        incoming.records[0].id = UUID()
        incoming.records[0].shipmentID = incoming.shipments[0].id
        let preview = try store.previewBackup(JSONEncoder().encode(incoming))
        _ = try store.importBackup(preview, policy: .replaceExisting)
        XCTAssertEqual(try store.snapshot().shipments.map(\.id), incoming.shipments.map(\.id))
        XCTAssertThrowsError(try store.cleanupRetiredShipmentPhones(clear: phones.clear))
        XCTAssertEqual(try phones.read(for: shipment), "9276")
        XCTAssertNotNil(cacheKeys.value)
        cacheKeys.failDelete = false
        let restarted = try SharedPickupStore(appGroupID: nil, containerURL: root)
        try restarted.cleanupRetiredShipmentPhones(clear: phones.clear)
        XCTAssertNil(cacheKeys.value)
        XCTAssertNil(try phones.read(for: shipment))
        XCTAssertThrowsError(try cache.lookup(identity))
    }
    @MainActor
    func testAppDeleteClearsBothSecretsAndRespectsActiveLease() throws {
        let cacheKeys = Keys(); let phoneKeys = Keys()
        let cache = PaidTrackingCache(directory: root.appendingPathComponent("cache"), phoneKeys: { _ in cacheKeys })
        let phones = ShipmentPhoneStore(keys: phoneKeys, cache: cache)
        let app = ShipmentStore(storageProvider: { self.store })
        app.shipmentPhones = phones
        try phones.save("9276", for: shipment)
        let old = try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276")
        let lease = try store.acquireTrackingQuery(id: shipment.id)
        XCTAssertThrowsError(try app.deleteThrowing(id: shipment.id))
        XCTAssertEqual(try phones.read(for: shipment), "9276")
        XCTAssertNotNil(cacheKeys.value)
        lease.release()
        try app.deleteThrowing(id: shipment.id)
        XCTAssertTrue(try store.snapshot().shipments.isEmpty)
        XCTAssertNil(cacheKeys.value)
        XCTAssertNil(try phones.read(for: shipment))
        XCTAssertThrowsError(try cache.lookup(old))
    }
    func testFailedPhoneSaveAlreadyInvalidatesLateResponse() throws {
        let cacheKeys = Keys(); let phoneKeys = Keys()
        let cache = PaidTrackingCache(directory: root.appendingPathComponent("cache"), phoneKeys: { _ in cacheKeys })
        let phones = ShipmentPhoneStore(keys: phoneKeys, cache: cache)
        try phones.save("9276", for: shipment)
        let old = try cache.identity(channel: "uapi", number: shipment.trackingNumber, generation: "g", phone: "9276")
        phoneKeys.failSave = true
        XCTAssertThrowsError(try phones.save("8351", for: shipment))
        XCTAssertNil(cacheKeys.value)
        XCTAssertThrowsError(try cache.lookup(old))
        XCTAssertEqual(try phones.read(for: shipment), "9276")
    }
    @MainActor
    func testOldMainAppButtonRejectsEditsMoveAndCompletionCycle() throws {
        let app = ShipmentStore(storageProvider: { self.store })
        let displayed = try store.snapshot().records[0]
        let otherGroupID = try XCTUnwrap(store.snapshot().groups.first { $0.id != displayed.groupID }?.id)
        for kind in 0..<4 {
            try store.transaction { data in
                // Keep each edited fixture structurally valid before testing staleness.
                data.shipments = [self.shipment]
                data.records[0] = displayed
                switch kind {
                case 0:
                    data.records[0].code = "NEW"
                    data.shipments[0].pickupCode = "NEW"
                case 1: data.records[0].groupID = otherGroupID
                case 2:
                    data.records[0].shipmentID = nil
                    data.shipments.removeAll()
                default: data.records[0].updatedAt = displayed.updatedAt.addingTimeInterval(1)
                }
            }
            let before = try store.exportBackup()
            XCTAssertThrowsError(try app.setPickupCompleted(id: displayed.id, completed: false, expected: displayed))
            XCTAssertEqual(try store.exportBackup(), before)
        }
        let latest = try store.snapshot().records[0]
        try app.setPickupCompleted(id: latest.id, completed: false, expected: latest)
        XCTAssertFalse(try store.snapshot().records[0].isCompleted)
        // Existing callers retain explicit reopen compatibility.
        try app.setPickupCompleted(id: latest.id, completed: true)
        XCTAssertTrue(try store.snapshot().records[0].isCompleted)
    }
    func testTerminalOldConflictAndNewJobRaceNeverRepeatPOST() async throws {
        for mode in 0..<4 {
            let credential = KDYZMCredential(baseURL: "https://example.com", token: "pcd_TEST_ONLY", deviceID: "d", generation: UUID())
            let keys = KDYZMNetworkTests.Keys(); keys.value = credential
            let transport = Transport()
            try store.transaction { data in
                data.shipments[0] = self.shipment
                data.shipments[0].originPlatform = "jd"
                data.shipments[0].platformOrderID = "123456"
                data.shipments[0].backendBinding = .init(origin: credential.baseURL, accountID: "a", orderID: "o", shipmentID: "s")
                data.shipments[0].backendRefreshJobID = "old-job"
                data.shipments[0].backendRefreshGeneration = credential.generation
                data.shipments[0].logisticsTime = Date(timeIntervalSince1970: 200)
                data.shipments[0].logisticsInfo = "本地轨迹"
            }
            let before = try store.snapshot().shipments[0]
            let eventTime = mode == 0 ? 100_000 : (mode == 3 ? 300_000 : 200_000)
            let snapshot: [String: Any] = ["schemaVersion": 1, "serverRevision": 1, "accounts": [],
                "orders": [["id": "o", "accountId": "a", "platform": "jd", "platformOrderId": "123456"]],
                "shipments": [["id": "s", "orderId": "o", "accountId": "a", "waybillNo": shipment.trackingNumber, "carrier": "圆通", "status": "arrived", "logisticsState": "ok", "logisticsCheckedAt": 300_000, "logisticsUpdatedAt": 300_000,
                    "logisticsEvents": [["time": eventTime, "timeText": "", "description": "远端轨迹", "location": ""]]]],
                "hiddenIds": [], "deletedIds": [], "legacyAccountIds": ["a"], "familyIds": []]
            transport.bodies = [Data(#"{"job":{"id":"old-job","accountId":"a","orderId":"o","state":"completed","logisticsState":"ok","createdAt":50000}}"#.utf8), try JSONSerialization.data(withJSONObject: snapshot)]
            if mode == 2 { transport.onSnapshot = { try self.store.transaction { $0.shipments[0].backendRefreshJobID = "new-job" } } }
            let service = KDYZMRefreshService(store: store, connection: KDYZMConnection(keys: keys), client: KDYZMClient(transport: transport), reloadWidgets: {})
            do {
                _ = try await service.refresh(before: before)
                XCTAssertEqual(mode, 3)
            } catch {
                XCTAssertNotEqual(mode, 3)
                if mode != 2 { XCTAssertTrue(error is KDYZMTerminalResultError) }
            }
            let after = try store.snapshot().shipments[0]
            XCTAssertEqual(after.backendRefreshJobID, mode == 2 ? "new-job" : nil)
            if mode != 3 { XCTAssertEqual(after.logisticsInfo, "本地轨迹") }
            else { XCTAssertEqual(after.logisticsInfo, "远端轨迹") }
            XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod == "GET" })
            XCTAssertEqual(transport.requests.count, 2)
        }
    }
}
