// Legacy direct marketplace import is opt-in; source is retained for restoration.
#if ENABLE_DIRECT_MALL_IMPORT
import XCTest
@testable import ParcelKeeper

@MainActor final class TaobaoBindingTests: XCTestCase {
    func testReimportBindsExistingRecordWithoutOverwritingUserData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("missing"), containerURL: root)
        let store = ShipmentStore(storageProvider: { storage })
        let original = Shipment(trackingNumber: "SF1234567890123", carrierName: "顺丰", carrierCode: "sf", note: "原备注", pickupCode: "A001")
        try store.addThrowing(original)
        let candidate = TaobaoTrialCandidate(number: original.trackingNumber, carrier: "顺丰", title: "新商品", orderID: "12345678")
        let result = try store.importTaobao(candidate)
        XCTAssertEqual(result, original.id)
        let after = try storage.snapshot().shipments[0]
        XCTAssertEqual(after.note, original.note)
        XCTAssertEqual(after.pickupCode, original.pickupCode)
        XCTAssertEqual(after.createdAt, original.createdAt)
        XCTAssertEqual(after.updatedAt, original.updatedAt)
        XCTAssertEqual(after.taobaoOrderID, "12345678")
        XCTAssertEqual(after.originPlatform, "taobao")
        XCTAssertThrowsError(try store.importTaobao(.init(number: original.trackingNumber, carrier: "顺丰", title: "", orderID: "22345678")))
        XCTAssertEqual(try storage.snapshot().shipments[0].taobaoOrderID, "12345678")
    }
}
#endif
