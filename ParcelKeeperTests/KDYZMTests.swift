import XCTest
@testable import ParcelKeeper

final class KDYZMTests: XCTestCase {
    func testOriginRejectsCredentialsPathsAndNonHTTPS() throws {
        for raw in ["http://example.com", "https://u:p@example.com", "https://example.com/a", "https://example.com?q=x", "https://example.com#x", " https://example.com"] {
            XCTAssertThrowsError(try KDYZMOrigin(raw))
        }
        XCTAssertEqual(try KDYZMOrigin("https://192.168.1.2:8443").value, "https://192.168.1.2:8443")
    }
    func testSafeErrorsNeverEchoServerContent() {
        XCTAssertEqual(KDYZMError.unauthorized.localizedDescription, "设备授权已失效，请先解绑后重新绑定。")
        XCTAssertFalse(KDYZMError.invalid.localizedDescription.contains("token"))
    }
    func testMilliseconds() throws {
        XCTAssertEqual(try KDYZMTime.date(1_700_000_000_000)?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(try KDYZMTime.date(0))
        XCTAssertThrowsError(try KDYZMTime.date(-1))
    }
    private func snapshot(familyIds: [String]? = ["f"], legacy: [String] = [], accounts: [KDYZMAccount] = []) -> KDYZMSnapshot {
        KDYZMSnapshot(schemaVersion: 1, serverRevision: 1, accounts: accounts,
            orders: [.init(id: "o", accountId: "a", platform: "jd", platformOrderId: "123456", familyId: "f", title: "标题")],
            shipments: [.init(id: "s", orderId: "o", accountId: "a", familyId: "f", waybillNo: "JD123456789012", carrier: "京东物流", status: "signed")],
            hiddenIds: [], deletedIds: [], familyIds: familyIds, legacyAccountIds: legacy, families: [])
    }
    func testHistoricalFamilyAllowsAbsentCurrentAccountButNotEmptyScope() throws {
        XCTAssertNoThrow(try snapshot().validated())
        XCTAssertThrowsError(try snapshot(familyIds: []).validated())
        XCTAssertNoThrow(try snapshot(familyIds: [], legacy: ["a"]).validated())
    }
    func testDuplicateAndCrossAccountRelationsRejectEntireSnapshot() throws {
        var s = snapshot(); s.shipments.append(s.shipments[0])
        XCTAssertThrowsError(try s.validated())
        s = snapshot(); s.shipments[0].accountId = "other"
        XCTAssertThrowsError(try s.validated())
        s = snapshot(); s.schemaVersion = 2
        XCTAssertThrowsError(try s.validated())
    }
    func testMergePreservesUserFieldsAndManualCompletion() throws {
        let group = PickupGroup(name: "自选", sortOrder: 0)
        let local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd", note: "本地备注", pickupCode: "42", reminderDate: Date())
        let record = PickupRecord(groupID: group.id, code: "42", source: "本地备注", isCompleted: false, shipmentID: local.id)
        var d = PickupDataset(groups: [group], records: [record], shipments: [local], expressGroupID: group.id)
        _ = try KDYZMMerger.apply(snapshot(), origin: "https://example.com", to: &d)
        XCTAssertEqual(d.shipments[0].id, local.id)
        XCTAssertEqual(d.shipments[0].note, local.note)
        XCTAssertEqual(d.shipments[0].pickupCode, local.pickupCode)
        XCTAssertEqual(d.shipments[0].reminderDate, local.reminderDate)
        XCTAssertFalse(d.records[0].isCompleted)
        XCTAssertNil(d.shipments[0].lastQueriedAt)
        XCTAssertEqual(d.records[0].groupID, group.id)
    }
    func testHiddenAndAbsentNeverDelete() throws {
        var s = snapshot(); s.hiddenIds = ["s"]
        let g = PickupGroup(name: "快递", sortOrder: 0)
        var d = PickupDataset(groups: [g], records: [], shipments: [], expressGroupID: g.id)
        XCTAssertEqual(try KDYZMMerger.apply(s, origin: "https://example.com", to: &d).imported, 0)
        XCTAssertTrue(d.shipments.isEmpty)
    }
    func testTwoAccountsSameNumberDoNotMergeAndAmbiguousLocalRejects() throws {
        var s = snapshot()
        s.orders.append(.init(id: "other-order", accountId: "other-account", platform: "jd", platformOrderId: "654321", familyId: "f"))
        var other = s.shipments[0]
        other.id = "other-shipment"; other.orderId = "other-order"; other.accountId = "other-account"
        s.shipments.append(other)
        let g = PickupGroup(name: "快递", sortOrder: 0)
        var d = PickupDataset(groups: [g], records: [], shipments: [], expressGroupID: g.id)
        _ = try KDYZMMerger.apply(s, origin: "https://example.com", to: &d)
        XCTAssertEqual(d.shipments.count, 2)
        XCTAssertEqual(Set(d.shipments.compactMap(\.backendBinding)).count, 2)
        let local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd")
        d = PickupDataset(groups: [g], records: [PickupRecord(groupID: g.id, code: "", source: "", shipmentID: local.id)], shipments: [local], expressGroupID: g.id)
        XCTAssertThrowsError(try KDYZMMerger.apply(s, origin: "https://example.com", to: &d))
    }
    func testRetiredIdentityCarrierAndChannelRejectLateIdentity() {
        let before = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd")
        var changed = before; changed.trackingNumber = "JD999999999999"
        XCTAssertFalse(KDYZMMerger.sameIdentity(changed, before))
        changed = before; changed.carrierCode = "sf"
        XCTAssertFalse(KDYZMMerger.sameIdentity(changed, before))
        changed = before; changed.refreshChannel = "uapi"
        XCTAssertFalse(KDYZMMerger.sameIdentity(changed, before))
        changed = before; changed.id = UUID()
        XCTAssertFalse(KDYZMMerger.sameIdentity(changed, before))
    }
    func testArchivedSkippedAndOverrideKeepsLogistics() throws {
        let g = PickupGroup(name: "快递", sortOrder: 0)
        var local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd")
        local.status = .archived
        var d = PickupDataset(groups: [g], records: [PickupRecord(groupID: g.id, code: "", source: "", shipmentID: local.id)], shipments: [local], expressGroupID: g.id)
        XCTAssertEqual(try KDYZMMerger.apply(snapshot(), origin: "https://example.com", to: &d).skipped, 1)
        XCTAssertEqual(d.shipments[0], local)
        local.status = .inTransit; local.refreshChannel = "uapi"; local.logisticsSource = "uapi"; local.logisticsInfo = "个人轨迹"
        d.shipments = [local]
        var s = snapshot(); s.shipments[0].logisticsState = "ok"; s.shipments[0].logisticsUpdatedAt = 300_000
        s.shipments[0].logisticsEvents = [.init(time: 300_000, timeText: "", description: "远端轨迹", location: "")]
        _ = try KDYZMMerger.apply(s, origin: "https://example.com", to: &d)
        XCTAssertNotNil(d.shipments[0].backendBinding)
        XCTAssertEqual(d.shipments[0].refreshChannel, "uapi")
        XCTAssertEqual(d.shipments[0].logisticsInfo, "个人轨迹")
        XCTAssertEqual(d.shipments[0].status, .inTransit)
    }
    func testEmptyCacheNewStatusDoesNotMeanCollected() throws {
        for (remote, expected) in [("signed", ShipmentStatus.delivered), ("arrived", .readyForPickup)] {
            let g = PickupGroup(name: "快递", sortOrder: 0)
            var d = PickupDataset(groups: [g], records: [], shipments: [], expressGroupID: g.id)
            var s = snapshot(); s.shipments[0].status = remote; s.shipments[0].logisticsState = "empty"
            _ = try KDYZMMerger.apply(s, origin: "https://example.com", to: &d)
            XCTAssertEqual(d.shipments[0].status, expected)
            XCTAssertFalse(d.records[0].isCompleted)
            XCTAssertNil(d.shipments[0].lastQueriedAt)
        }
    }
    func testPickupCodeFillsOnlyEmptyAndRejectsGroupDuplicate() throws {
        let g = PickupGroup(name: "快递", sortOrder: 0)
        let local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd")
        var d = PickupDataset(groups: [g], records: [PickupRecord(groupID: g.id, code: "", source: "", shipmentID: local.id)], shipments: [local], expressGroupID: g.id)
        var s = snapshot(); s.shipments[0].pickupCode = "42"
        _ = try KDYZMMerger.apply(s, origin: "https://example.com", to: &d)
        XCTAssertEqual(d.shipments[0].pickupCode, "42"); XCTAssertEqual(d.records[0].code, "42")
        s.shipments[0].pickupCode = "99"
        _ = try KDYZMMerger.apply(s, origin: "https://example.com", to: &d)
        XCTAssertEqual(d.shipments[0].pickupCode, "42")
        d.shipments[0].pickupCode = ""; d.records[0].code = ""
        d.records.append(PickupRecord(groupID: g.id, code: "99", source: ""))
        XCTAssertThrowsError(try KDYZMMerger.apply(s, origin: "https://example.com", to: &d))
        s.shipments[0].station = String(repeating: "x", count: 201)
        XCTAssertThrowsError(try s.validated())
    }
    func testLatestConflictAndReadyCannotRegress() throws {
        var local = Shipment(trackingNumber: "JD123456789012", carrierName: "京东物流", carrierCode: "jd", logisticsInfo: "原节点", logisticsTime: Date(timeIntervalSince1970: 200))
        local.status = .readyForPickup
        var remote = snapshot().shipments[0]; remote.status = "transit"; remote.logisticsState = "ok"; remote.logisticsUpdatedAt = 400_000
        remote.logisticsEvents = [.init(time: 200_000, timeText: "", description: "冲突节点", location: "")]
        let before = local
        XCTAssertFalse(try KDYZMMerger.update(remote, local: &local)); XCTAssertEqual(local, before)
        remote.logisticsEvents = [.init(time: 300_000, timeText: "", description: "较新节点", location: "")]
        XCTAssertTrue(try KDYZMMerger.update(remote, local: &local)); XCTAssertEqual(local.status, .readyForPickup)
    }
    func testScopeAndTokenValidation() throws {
        var scope = KDYZMScope(familyIds: [], legacyAccountIds: ["a"], families: [], accountIds: ["a"], accounts: [.init(id: "a", platform: "jd", label: "账号")], includeFutureAccounts: false)
        XCTAssertNoThrow(try scope.validated())
        scope.accounts.append(scope.accounts[0]); XCTAssertThrowsError(try scope.validated())
        XCTAssertTrue(KDYZMClient.validToken("pcd_TEST_ONLY"))
        for token in ["pcd_", "Bearer secret", "pcd_a\n", "secret"] { XCTAssertFalse(KDYZMClient.validToken(token)) }
    }
    func testQueuedAndFailedJobAreNotSuccess() throws {
        let binding = KDYZMBinding(origin: "https://example.com", accountID: "a", orderID: "o", shipmentID: "s")
        for state in ["queued", "running", "cooldown", "disabled", "expired", "error"] {
            let job = KDYZMJob(id: "j", accountId: "a", orderId: "o", state: state)
            XCTAssertFalse(try job.success(for: binding, expectedID: "j"))
        }
        let failed = KDYZMJob(id: "j", accountId: "a", orderId: "o", state: "completed", logisticsState: "error")
        XCTAssertFalse(try failed.success(for: binding, expectedID: "j"))
        XCTAssertThrowsError(try failed.success(for: binding, expectedID: "wrong"))
    }
}
