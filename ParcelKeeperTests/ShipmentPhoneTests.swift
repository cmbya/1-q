import XCTest
@testable import ParcelKeeper

extension TrackingRefreshTests {
    final class PhoneKeys: AIKeyStore {
        var values: [String: String] = [:]
        var fail = false
        func read() throws -> String? { nil }
        func save(_ key: String) throws {}
        func delete() throws {}
        func read(endpoint: String) throws -> String? { if fail { throw UAPIError.keychain }; return values[endpoint] }
        func save(_ key: String, endpoint: String) throws { if fail { throw UAPIError.keychain }; values[endpoint] = key }
        func delete(endpoint: String) throws { if fail { throw UAPIError.keychain }; values.removeValue(forKey: endpoint) }
    }
    func testPhoneStoreIsPerRecordAndNumberWithStrictValidation() throws {
        let keys = PhoneKeys(); let phones = ShipmentPhoneStore(keys: keys)
        try phones.save("0123", for: shipment)
        XCTAssertEqual(try phones.read(for: shipment), "0123")
        var other = shipment!; other.id = UUID()
        XCTAssertNil(try phones.read(for: other))
        other = shipment!; other.trackingNumber = "SF1234567890123"
        XCTAssertNil(try phones.read(for: other))
        for invalid in ["123", "12345", " 1234", "１２３４", "12a4", ""] {
            XCTAssertThrowsError(try phones.save(invalid, for: shipment))
        }
        XCTAssertEqual(try phones.read(for: shipment), "0123")
        try phones.clear(for: shipment)
        XCTAssertNil(try phones.read(for: shipment))
    }
    func testPhoneReusedAfterFailureAndChangedOrClearedWithoutQuery() async throws {
        let keys = PhoneKeys(); let client = Client(); client.failure = UAPIError.noData
        var service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        service.phones = ShipmentPhoneStore(keys: keys)
        do { _ = try await service.refresh(id: shipment.id, phone: "0123"); XCTFail() } catch UAPIError.noData {}
        XCTAssertEqual(try service.savedPhone(id: shipment.id), "0123")
        do { _ = try await service.refresh(trackingNumber: shipment.trackingNumber); XCTFail() } catch UAPIError.noData {}
        XCTAssertEqual(client.queriedPhones, ["0123", "0123"])
        try service.setPhone(id: shipment.id, phone: "5678")
        XCTAssertEqual(client.calls, 2)
        XCTAssertEqual(try service.savedPhone(id: shipment.id), "5678")
        try service.setPhone(id: shipment.id, phone: nil)
        do { _ = try await service.refresh(id: shipment.id); XCTFail() } catch UAPIError.noData {}
        XCTAssertNil(client.queriedPhones.last!)
    }
    func testBatchReusesOnlyEachTicketsPhoneAndBackupExcludesIt() async throws {
        try addPhoneTestShipment()
        let keys = PhoneKeys(); let client = Client(); client.failure = UAPIError.noData
        var service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        service.phones = ShipmentPhoneStore(keys: keys)
        let backup = try storage.exportBackup()
        try service.setPhone(id: shipment.id, phone: "0123")
        XCTAssertEqual(try storage.exportBackup(), backup)
        let report = try await service.refreshPending()
        XCTAssertEqual(report.failed, 2)
        let index = try XCTUnwrap(client.queriedNumbers.firstIndex(of: shipment.trackingNumber))
        XCTAssertEqual(client.queriedPhones[index], "0123")
        XCTAssertNil(client.queriedPhones[1 - index])
    }
    private func addPhoneTestShipment() throws {
        var other = shipment!; other.id = UUID(); other.trackingNumber = "SF1234567890123"
        try storage.transaction { data in
            data.shipments.append(other)
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: "other", shipmentID: other.id))
        }
    }
    func testInvalidPhoneAndKeychainFailureNeverDispatch() async throws {
        let keys = PhoneKeys(); let client = Client()
        var service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        service.phones = ShipmentPhoneStore(keys: keys)
        do { _ = try await service.refresh(id: shipment.id, phone: "123"); XCTFail() } catch UAPIError.invalidPhone {}
        keys.fail = true
        do { _ = try await service.refresh(id: shipment.id); XCTFail() } catch UAPIError.keychain {}
        XCTAssertEqual(client.calls, 0)
    }
    func testPhoneChangeDuringQueryCannotRaceWithClearing() async throws {
        let keys = PhoneKeys(); let client = Client()
        var service = TrackingRefreshService(store: storage, client: client, reloadWidgets: {})
        service.phones = ShipmentPhoneStore(keys: keys)
        let captured = service
        client.onQuery = {
            XCTAssertThrowsError(try captured.setPhone(id: self.shipment.id, phone: nil))
        }
        _ = try await service.refresh(id: shipment.id, phone: "0123")
        XCTAssertEqual(try service.savedPhone(id: shipment.id), "0123")
    }
}
