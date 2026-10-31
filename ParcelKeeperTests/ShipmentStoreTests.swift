import XCTest
import Darwin
@testable import ParcelKeeper

@MainActor
final class ShipmentStoreTests: XCTestCase {
    private func fixture() throws -> (URL, SharedPickupStore, ShipmentStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("absent.json"), containerURL: root)
        let app = ShipmentStore(storageProvider: { shared })
        return (root, shared, app)
    }

    private func shipment(_ status: ShipmentStatus) -> Shipment {
        Shipment(trackingNumber: UUID().uuidString, carrierName: "测试", carrierCode: "test", status: status, note: "来源", pickupCode: "42")
    }

    func testCreateGroupAppendsUsingLatestOrderAcrossStaleStores() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherShared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("absent.json"), containerURL: root)
        let other = ShipmentStore(storageProvider: { otherShared })
        let original = app.groups.map(\.id)
        let first = try other.createGroup(name: "先添加")
        let second = try app.createGroup(name: "后添加")
        XCTAssertEqual(app.groups.map(\.id), original + [first, second])
        XCTAssertEqual(Set(app.groups.map(\.sortOrder)).count, app.groups.count)
        let reversed = Array(app.groups.map(\.id).reversed())
        try other.reorderGroups(ids: reversed)
        let third = try app.createGroup(name: "排序后添加")
        XCTAssertEqual(app.groups.map(\.id), reversed + [third])
        XCTAssertEqual(try shared.snapshot().groups.count, original.count + 3)
    }

    func testCreateGroupAfterExtremeBackupNormalizesOrderWithoutChangingIdentity() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let groupID = try XCTUnwrap(app.groups.first?.id)
        _ = try app.addPickupRecord(groupID: groupID, code: "保留关联")
        var incoming = try shared.snapshot()
        // Include tied maximum values and a negative value in non-business array order.
        incoming.groups[0].sortOrder = Int.max
        incoming.groups[1].sortOrder = Int.min
        incoming.groups.append(PickupGroup(name: "同序分组", sortOrder: Int.max))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let preview = try shared.previewBackup(encoder.encode(incoming))
        try app.confirmBackupImport(preview, policy: .replaceExisting)
        let before = try shared.snapshot()
        let ordered = before.groups.sorted { $0.sortOrder < $1.sortOrder }
        let created = try app.createGroup(name: "极值后添加")
        let after = try shared.snapshot()
        XCTAssertEqual(app.groups.map(\.id), ordered.map(\.id) + [created])
        XCTAssertEqual(app.groups.map(\.sortOrder), Array(0..<app.groups.count))
        for group in before.groups {
            var expected = group
            expected.sortOrder = try XCTUnwrap(ordered.firstIndex { $0.id == group.id })
            XCTAssertEqual(after.groups.first { $0.id == group.id }, expected)
        }
        XCTAssertEqual(after.expressGroupID, before.expressGroupID)
        XCTAssertEqual(after.records, before.records)
        XCTAssertEqual(after.shipments, before.shipments)
    }

    func testManualCarrierCorrectionClearsOnlyStaleProviderCode() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = shipment(.inTransit)
        value.carrierCode = "yto"
        value.uapiCarrierCode = "yuantong"
        value.queryInfo = "保留旧查询"
        try app.addThrowing(value)
        let same = try XCTUnwrap(CarrierDetector.allCarriers.first { $0.code == "yto" })
        app.updateCarrier(id: value.id, carrier: same)
        XCTAssertEqual(try shared.snapshot().shipments[0].uapiCarrierCode, "yuantong")
        let different = try XCTUnwrap(CarrierDetector.allCarriers.first { $0.code != "yto" })
        app.updateCarrier(id: value.id, carrier: different)
        let after = try XCTUnwrap(shared.snapshot().shipments.first)
        XCTAssertNil(after.uapiCarrierCode)
        XCTAssertEqual(after.carrierCode, different.code)
        XCTAssertEqual(after.queryInfo, value.queryInfo)
        XCTAssertEqual(after.note, value.note)
        XCTAssertEqual(after.pickupCode, value.pickupCode)
    }

    func testUnknownCarrierRenameClearsProviderCodeButTrimmedNamePreservesIt() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = shipment(.readyForPickup)
        value.carrierCode = "unknown"
        value.carrierName = "自定义甲"
        value.uapiCarrierCode = "old-provider"
        value.reminderDate = Date(timeIntervalSinceReferenceDate: 123)
        value.logisticsInfo = "保留物流"
        value.queryInfo = "保留查询"
        try app.addThrowing(value)
        app.updateCarrier(id: value.id, carrier: CarrierOption(id: "custom", name: " 自定义甲\n", code: "unknown"))
        XCTAssertEqual(try shared.snapshot().shipments[0].uapiCarrierCode, "old-provider")
        try app.updateCarrierThrowing(id: value.id, carrier: CarrierOption(id: "custom", name: "自定义乙", code: "unknown"))
        let after = try XCTUnwrap(shared.snapshot().shipments.first)
        XCTAssertNil(after.uapiCarrierCode)
        XCTAssertEqual(after.carrierName, "自定义乙")
        XCTAssertEqual(after.carrierCode, "unknown")
        XCTAssertEqual(after.id, value.id)
        XCTAssertEqual(after.createdAt, value.createdAt)
        XCTAssertEqual(after.note, value.note)
        XCTAssertEqual(after.pickupCode, value.pickupCode)
        XCTAssertEqual(after.reminderDate, value.reminderDate)
        XCTAssertEqual(after.logisticsInfo, value.logisticsInfo)
        XCTAssertEqual(after.queryInfo, value.queryInfo)
    }

    func testThrowingShipmentEditsReportMissingRecords() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = UUID()
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.updateNoteThrowing(id: missing, note: "note"))
        XCTAssertThrowsError(try app.updatePickupCodeThrowing(id: missing, pickupCode: "code"))
        XCTAssertThrowsError(try app.updateCarrierThrowing(id: missing, carrier: CarrierDetector.unknown))
        XCTAssertThrowsError(try app.updateStatusThrowing(id: missing, status: .delivered))
        XCTAssertThrowsError(try app.markCheckedThrowing(id: missing))
        XCTAssertEqual(try shared.snapshot(), before)
    }

    func testThrowingShipmentEditsRollBackDuplicateCodeAndReopening() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = shipment(.readyForPickup)
        value.pickupCode = "original"
        try app.addThrowing(value)
        let linked = try XCTUnwrap(app.pickupRecords.first { $0.shipmentID == value.id })
        _ = try app.addPickupRecord(groupID: linked.groupID, code: "42")
        let before = try shared.snapshot()
        let beforeShipments = app.shipments
        let beforeRecords = app.pickupRecords
        XCTAssertThrowsError(try app.updatePickupCodeThrowing(id: value.id, pickupCode: " 42 "))
        XCTAssertEqual(try shared.snapshot(), before)
        XCTAssertEqual(app.shipments, beforeShipments)
        XCTAssertEqual(app.pickupRecords, beforeRecords)
        try app.updateStatusThrowing(id: value.id, status: .delivered)
        try app.updatePickupCodeThrowing(id: value.id, pickupCode: "42")
        let completed = try shared.snapshot()
        let completedShipments = app.shipments
        let completedRecords = app.pickupRecords
        XCTAssertThrowsError(try app.updateStatusThrowing(id: value.id, status: .readyForPickup))
        XCTAssertEqual(try shared.snapshot(), completed)
        XCTAssertEqual(app.shipments, completedShipments)
        XCTAssertEqual(app.pickupRecords, completedRecords)
        try app.updateNoteThrowing(id: value.id, note: "saved")
        try app.markCheckedThrowing(id: value.id)
        XCTAssertEqual(app.shipment(id: value.id)?.note, "saved")
        XCTAssertNotNil(app.shipment(id: value.id)?.lastCheckedAt)
    }

    func testNewShipmentCompletionMatchesInitialStatus() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for status in ShipmentStatus.allCases {
            var value = shipment(status)
            value.pickupCode = status.rawValue
            try app.addThrowing(value)
            let data = try shared.snapshot()
            let record = try XCTUnwrap(data.records.first { $0.shipmentID == value.id })
            XCTAssertEqual(record.isCompleted, status == .delivered || status == .archived)
        }
    }

    func testStatusChangesOnlySynchronizeLinkedRecordAndPreserveExplicitRestoreOnOtherEdits() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = shipment(.readyForPickup)
        try app.addThrowing(value)
        let group = try XCTUnwrap(app.groups.last?.id)
        let standalone = try app.addPickupRecord(groupID: group, code: "42")
        try app.setPickupCompleted(id: standalone, completed: true)
        let linked = try XCTUnwrap(app.pickupRecords.first { $0.shipmentID == value.id }?.id)
        app.updateStatus(id: value.id, status: .delivered)
        XCTAssertTrue(try XCTUnwrap(app.pickupRecords.first { $0.id == linked }).isCompleted)
        try app.setPickupCompleted(id: linked, completed: false)
        app.updateNote(id: value.id, note: "新来源")
        try app.updateReminderThrowing(id: value.id, date: Date())
        app.updateStatus(id: value.id, status: .delivered) // no actual status change
        XCTAssertFalse(try XCTUnwrap(app.pickupRecords.first { $0.id == linked }).isCompleted)
        app.updateStatus(id: value.id, status: .archived)
        XCTAssertTrue(try XCTUnwrap(app.pickupRecords.first { $0.id == linked }).isCompleted)
        app.updateStatus(id: value.id, status: .readyForPickup)
        XCTAssertFalse(try XCTUnwrap(app.pickupRecords.first { $0.id == linked }).isCompleted)
        XCTAssertTrue(try XCTUnwrap(shared.snapshot().records.first { $0.id == standalone }).isCompleted)
        try app.setPickupCompleted(id: standalone, completed: false)
        app.updateNote(id: value.id, note: "再次编辑")
        XCTAssertFalse(try XCTUnwrap(shared.snapshot().records.first { $0.id == standalone }).isCompleted)
        XCTAssertEqual(app.shipment(id: value.id)?.status, .readyForPickup)
    }

    func testStaleEditorPreservesConcurrentUneditedFieldsAndRejectsSameFieldConflict() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = shipment(.readyForPickup)
        try app.addThrowing(value)
        let original = try XCTUnwrap(app.pickupRecords.first)
        let other = ShipmentStore(storageProvider: { shared })
        other.updatePickupCode(id: value.id, pickupCode: "NEW")
        try other.setPickupCompleted(id: original.id, completed: true)
        try app.updatePickupRecord(id: original.id, code: original.code, location: "新位置", source: original.source, expected: original)
        let latest = try XCTUnwrap(shared.snapshot().records.first)
        XCTAssertEqual(latest.code, "NEW")
        XCTAssertEqual(latest.location, "新位置")
        XCTAssertTrue(latest.isCompleted)
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.updatePickupRecord(id: original.id, code: "MY-EDIT", location: "不得部分提交", expected: original))
        XCTAssertEqual(try shared.snapshot(), before)
        try app.updatePickupRecord(id: original.id, source: "仅来源", expected: latest)
        XCTAssertEqual(try shared.snapshot().shipments.first?.pickupCode, "NEW")
        XCTAssertEqual(try shared.snapshot().shipments.first?.note, "仅来源")
        let saved = try shared.snapshot()
        XCTAssertThrowsError(try app.updatePickupRecord(id: original.id, code: "  "))
        XCTAssertEqual(try shared.snapshot(), saved)
    }

    func testNewShipmentsRejectPendingCodeButAllowCompletedReuseAndEmptyCodes() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = shipment(.readyForPickup)
        try app.addThrowing(pending)
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.addThrowing(shipment(.readyForPickup)))
        XCTAssertEqual(try shared.snapshot(), before)
        try app.addThrowing(shipment(.delivered))
        try app.addThrowing(shipment(.archived))
        for _ in 0..<2 {
            var empty = shipment(.readyForPickup)
            empty.pickupCode = ""
            try app.addThrowing(empty)
        }
        XCTAssertEqual(try shared.snapshot().shipments.count, 5)
    }

    func testPendingDuplicateEditsMovesRestoresAndGroupMergeRollBack() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(app.groups.first?.id)
        let second = try XCTUnwrap(app.groups.last?.id)
        let occupied = try app.addPickupRecord(groupID: first, code: "42")
        let editable = try app.addPickupRecord(groupID: first, code: "other")
        let moving = try app.addPickupRecord(groupID: second, code: " 42\n")
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.updatePickupRecord(id: editable, code: "42", location: "must roll back"))
        XCTAssertThrowsError(try app.movePickupRecord(id: moving, to: first))
        XCTAssertThrowsError(try app.deleteGroup(id: second, moveTo: first))
        XCTAssertEqual(try shared.snapshot(), before)
        try app.setPickupCompleted(id: moving, completed: true)
        try app.movePickupRecord(id: moving, to: first) // completed codes can coexist
        try app.updatePickupRecord(id: moving, code: "42")
        let completed = try shared.snapshot()
        XCTAssertThrowsError(try app.setPickupCompleted(id: moving, completed: false))
        XCTAssertEqual(try shared.snapshot(), completed)
        try app.setPickupCompleted(id: occupied, completed: true)
        try app.setPickupCompleted(id: moving, completed: false)
        try app.updatePickupRecord(id: editable, code: "free")
        try app.movePickupRecord(id: editable, to: second)
        try app.deleteGroup(id: second, moveTo: first)
        XCTAssertFalse(try shared.snapshot().groups.contains { $0.id == second })
    }

    func testLinkedEditsAndStatusRestoreUseLatestTransactionalDuplicates() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var value = shipment(.readyForPickup)
        value.pickupCode = "original"
        try app.addThrowing(value)
        let linked = try XCTUnwrap(app.pickupRecords.first { $0.shipmentID == value.id })
        let other = ShipmentStore(storageProvider: { shared })
        let occupied = try other.addPickupRecord(groupID: linked.groupID, code: "42")
        let before = try shared.snapshot()
        app.updatePickupCode(id: value.id, pickupCode: " 42 ")
        XCTAssertNotNil(app.lastErrorMessage)
        XCTAssertEqual(try shared.snapshot(), before)
        XCTAssertThrowsError(try app.updatePickupRecord(id: linked.id, code: "42", source: "rollback"))
        XCTAssertEqual(try shared.snapshot(), before)
        app.updateStatus(id: value.id, status: .delivered)
        app.updatePickupCode(id: value.id, pickupCode: "42") // completed code reuse
        let completed = try shared.snapshot()
        app.updateStatus(id: value.id, status: .readyForPickup)
        XCTAssertEqual(try shared.snapshot(), completed)
        XCTAssertThrowsError(try app.setPickupCompleted(id: linked.id, completed: false))
        try other.setPickupCompleted(id: occupied, completed: true)
        app.updateStatus(id: value.id, status: .readyForPickup)
        XCTAssertFalse(try XCTUnwrap(shared.snapshot().records.first { $0.id == linked.id }).isCompleted)
    }

    func testHistoricalDuplicatesAllowUnrelatedEditsAndNoOpIdentityChanges() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = shipment(.readyForPickup)
        try app.addThrowing(value)
        let linked = try XCTUnwrap(app.pickupRecords.first)
        let duplicate = PickupRecord(groupID: linked.groupID, code: "42")
        try shared.transaction { $0.records.append(duplicate) } // legacy/backup data is valid
        try app.reload()
        try app.updatePickupRecord(id: duplicate.id, code: " 42 ", location: "new", source: "edited")
        try app.movePickupRecord(id: duplicate.id, to: linked.groupID)
        try app.setPickupCompleted(id: duplicate.id, completed: false)
        app.updateNote(id: value.id, note: "unrelated")
        try app.updateReminderThrowing(id: value.id, date: Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(app.shipment(id: value.id)?.note, "unrelated")
        XCTAssertEqual(app.pickupRecords.first { $0.id == duplicate.id }?.location, "new")
        let incoming = try shared.exportBackup()
        let freshRoot = root.appendingPathComponent("import")
        let fresh = try SharedPickupStore(appGroupID: nil, legacyURL: freshRoot.appendingPathComponent("absent"), containerURL: freshRoot)
        let imported = try fresh.importBackup(fresh.previewBackup(incoming), policy: nil)
        XCTAssertEqual(imported.records.filter { $0.groupID == linked.groupID }.count, 2)
    }

    func testInitialReadLockTimeoutRecoversOnReload() throws {
        let (root, shared, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try shared.snapshot()
        let url = root.appendingPathComponent("ParcelKeeper/pickup-data.lock")
        let fd = open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let recovering = ShipmentStore(storageProvider: { shared })
        XCTAssertNotNil(recovering.lastErrorMessage)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        try recovering.reload()
        XCTAssertNil(recovering.lastErrorMessage)
        XCTAssertEqual(Set(recovering.groups.map(\.id)), Set(initial.groups.map(\.id)))
        XCTAssertFalse(recovering.isHistoricalSnapshot)
    }
    func testNoAccessLegacyReloadKeepsSelectionIdentitiesAndNeverWritesHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ParcelKeeper")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("shipments.json")
        let bytes = try JSONEncoder().encode([shipment(.delivered)])
        try bytes.write(to: legacy)
        let history = ShipmentStore(storageProvider: { throw AppGroupResolver.ResolutionError.noAccess }, historicalContainerURL: root)
        XCTAssertTrue(history.isHistoricalSnapshot)
        let groups = history.groups
        let records = history.pickupRecords
        try history.reload()
        history.refreshOnForeground()
        XCTAssertEqual(history.groups, groups)
        XCTAssertEqual(history.pickupRecords, records)
        let reopened = ShipmentStore(storageProvider: { throw AppGroupResolver.ResolutionError.noAccess }, historicalContainerURL: root)
        XCTAssertEqual(reopened.groups, groups)
        XCTAssertEqual(reopened.pickupRecords, records)
        XCTAssertThrowsError(try history.createGroup(name: "forbidden"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["shipments.json"])
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testNoAccessShowsReadOnlyHistoryButChooseAndConflictNeverFallback() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try app.addThrowing(shipment(.delivered))
        let initial = try shared.snapshot()
        let dataURL = root.appendingPathComponent("ParcelKeeper/pickup-data.json")
        let bytes = try Data(contentsOf: dataURL)
        let history = ShipmentStore(storageProvider: { throw AppGroupResolver.ResolutionError.noAccess }, historicalContainerURL: root)
        XCTAssertTrue(history.isHistoricalSnapshot)
        XCTAssertEqual(history.shipments, app.shipments)
        XCTAssertTrue(history.lastErrorMessage?.contains("历史快照") == true)
        XCTAssertThrowsError(try history.createGroup(name: "禁止写入"))
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertEqual(try shared.snapshot(), initial)
        for failure in [AppGroupResolver.ResolutionError.chooseGroup, .conflict] {
            let blocked = ShipmentStore(storageProvider: { throw failure }, historicalContainerURL: root)
            XCTAssertFalse(blocked.isHistoricalSnapshot)
            XCTAssertTrue(blocked.shipments.isEmpty)
            XCTAssertEqual(blocked.lastErrorMessage, failure.localizedDescription)
            XCTAssertThrowsError(try blocked.createGroup(name: "禁止本地写入"))
        }
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
    }
}
