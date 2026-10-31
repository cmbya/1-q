import XCTest
import Darwin
@testable import ParcelKeeper

final class SharedPickupStoreTests: XCTestCase {
    private var root: URL!
    private var legacy: URL { root.appendingPathComponent("legacy.json") }
    private var container: URL { root.appendingPathComponent("container") }
    private var dataURL: URL { container.appendingPathComponent("ParcelKeeper/pickup-data.json") }
    private var backupURL: URL { container.appendingPathComponent("ParcelKeeper/shipments-legacy-backup.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
        root = nil
    }

    private func store(_ container: URL? = nil) throws -> SharedPickupStore {
        try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container ?? self.container)
    }

    private func shipment(code: String = "A-1") -> Shipment {
        Shipment(trackingNumber: "TEST-123", carrierName: "测试物流", carrierCode: "test",
                 status: .readyForPickup, note: "测试来源", pickupCode: code,
                 createdAt: Date(timeIntervalSinceReferenceDate: 1000.125),
                 updatedAt: Date(timeIntervalSinceReferenceDate: 2000.25),
                 lastCheckedAt: Date(timeIntervalSinceReferenceDate: 3000.5),
                 reminderDate: Date(timeIntervalSinceReferenceDate: 4000.75))
    }

    private func complete(_ store: SharedPickupStore, displayed record: PickupRecord) throws {
        try store.completePickup(groupID: record.groupID, recordID: record.id,
                                 expectedCode: record.code,
                                 expectedUpdatedAt: String(record.updatedAt.timeIntervalSinceReferenceDate))
    }

    func testWidgetCompletionRejectsChangedCodeEvenWhenVersionWasNotUpdated() throws {
        let s = try store()
        let group = try XCTUnwrap(s.snapshot().expressGroupID)
        let displayed = PickupRecord(groupID: group, code: "X", updatedAt: Date(timeIntervalSinceReferenceDate: 1234.125))
        try s.transaction { $0.records.append(displayed) }
        // Simulate another process updating the same ID while the old timeline remains visible.
        try store().transaction { $0.records[0].code = "Y" }
        let before = try s.snapshot()
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try complete(s, displayed: displayed)) { error in
            guard case PickupStorageError.staleCompletion = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try s.snapshot(), before)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertFalse(try XCTUnwrap(s.snapshot().records.first).isCompleted)
        try complete(s, displayed: XCTUnwrap(before.records.first))
        XCTAssertTrue(try XCTUnwrap(store().snapshot().records.first).isCompleted)
    }

    func testWidgetCompletionRejectsChangedVersionIncludingSameCodeAndRevertedCode() throws {
        let s = try store()
        let group = try XCTUnwrap(s.snapshot().expressGroupID)
        let displayed = PickupRecord(groupID: group, code: "X", updatedAt: Date(timeIntervalSinceReferenceDate: 1000.125))
        try s.transaction { $0.records.append(displayed) }
        // Strict version policy also rejects a note-only edit, despite an unchanged code.
        try store().transaction {
            $0.records[0].source = "changed note"
            $0.records[0].updatedAt = displayed.updatedAt.addingTimeInterval(0.125)
        }
        let before = try s.snapshot()
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try complete(s, displayed: displayed))
        XCTAssertEqual(try s.snapshot(), before)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        try s.transaction {
            $0.records[0].code = "Y"
            $0.records[0].updatedAt = displayed.updatedAt.addingTimeInterval(1)
        }
        try s.transaction {
            $0.records[0].code = "X"
            $0.records[0].updatedAt = displayed.updatedAt.addingTimeInterval(2)
        }
        let reverted = try s.snapshot()
        let revertedBytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try complete(s, displayed: displayed))
        XCTAssertEqual(try s.snapshot(), reverted)
        XCTAssertEqual(try Data(contentsOf: dataURL), revertedBytes)
    }

    func testWidgetCompletionRejectsLegacyMissingMalformedAndInexactSnapshotsWithoutWrites() throws {
        let s = try store()
        let group = try XCTUnwrap(s.snapshot().expressGroupID)
        let displayed = PickupRecord(groupID: group, code: "X-1", updatedAt: Date(timeIntervalSinceReferenceDate: 1000.125))
        try s.transaction { $0.records.append(displayed) }
        let before = try s.snapshot()
        let bytes = try Data(contentsOf: dataURL)
        let version = String(displayed.updatedAt.timeIntervalSinceReferenceDate)
        let snapshots: [(String?, String?)] = [
            (nil, nil), (nil, version), (displayed.code, nil),
            (displayed.code, ""), (displayed.code, "not-a-date"),
            (displayed.code, "nan"), (displayed.code, "inf"),
            ("", version), ("  ", version), (" X-1 ", version),
            (displayed.code, "1000")
        ]
        for (code, version) in snapshots {
            XCTAssertThrowsError(try s.completePickup(groupID: group, recordID: displayed.id,
                                                       expectedCode: code, expectedUpdatedAt: version)) { error in
                guard case PickupStorageError.staleCompletion = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try s.snapshot(), before)
            XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        }
    }

    func testWidgetCompletionRejectsMovedDeletedAndCompletedRecordsWithoutWrites() throws {
        let s = try store()
        let initial = try s.snapshot()
        let group = try XCTUnwrap(initial.expressGroupID)
        let otherGroup = try XCTUnwrap(initial.groups.first { $0.id != group }).id
        let displayed = PickupRecord(groupID: group, code: "X")
        try s.transaction { $0.records.append(displayed) }
        for mutation in 0..<3 {
            try s.transaction {
                switch mutation {
                case 0: $0.records[0].groupID = otherGroup
                case 1: $0.records = [displayed]; $0.records[0].isCompleted = true
                default: $0.records.removeAll()
                }
            }
            let before = try s.snapshot()
            let bytes = try Data(contentsOf: dataURL)
            XCTAssertThrowsError(try complete(s, displayed: displayed))
            XCTAssertEqual(try s.snapshot(), before)
            XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        }
    }

    func testWidgetCompletionPreservesLinkedShipmentDuplicateCodesAndManualReopen() throws {
        try JSONEncoder().encode([shipment()]).write(to: legacy)
        let s = try store()
        let initial = try s.snapshot()
        let displayed = try XCTUnwrap(initial.records.first)
        let duplicate = PickupRecord(groupID: displayed.groupID, code: displayed.code)
        try s.transaction { $0.records.append(duplicate) }
        try complete(s, displayed: displayed)
        let completed = try store().snapshot()
        XCTAssertTrue(try XCTUnwrap(completed.records.first { $0.id == displayed.id }).isCompleted)
        XCTAssertEqual(completed.records.first { $0.id == duplicate.id }, duplicate)
        XCTAssertEqual(completed.shipments, initial.shipments)
        let bytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try complete(s, displayed: displayed))
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        // Main-app manual reopen keeps the same logistics; an old action cannot undo it.
        try s.transaction {
            $0.records[0].isCompleted = false
            $0.records[0].updatedAt = displayed.updatedAt.addingTimeInterval(10)
        }
        let reopened = try s.snapshot()
        let reopenedBytes = try Data(contentsOf: dataURL)
        XCTAssertThrowsError(try complete(s, displayed: displayed))
        XCTAssertEqual(try Data(contentsOf: dataURL), reopenedBytes)
        XCTAssertEqual(try s.snapshot(), reopened)
        try complete(s, displayed: XCTUnwrap(reopened.records.first { $0.id == displayed.id }))
        XCTAssertTrue(try XCTUnwrap(s.snapshot().records.first { $0.id == displayed.id }).isCompleted)
        XCTAssertEqual(try s.snapshot().shipments, initial.shipments)
    }

    func testContendedLockTimesOutWithoutChangingDataAndRecoversAfterUnlock() throws {
        let s = try store()
        let initial = try s.snapshot()
        let bytes = try Data(contentsOf: dataURL)
        let lock = container.appendingPathComponent("ParcelKeeper/pickup-data.lock")
        let fd = open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        // Ensure an assertion failure cannot leave the lock held during teardown.
        defer { flock(fd, LOCK_UN) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try s.snapshot()) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ETIMEDOUT)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3.0)
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(try s.snapshot(), initial)
    }

    func testMigrationPreservesEveryShipmentFieldAndIsIdempotent() throws {
        let original = shipment()
        let bytes = try JSONEncoder().encode([original])
        try bytes.write(to: legacy)
        let first = try store().snapshot()
        XCTAssertEqual(first.shipments, [original])
        XCTAssertEqual(first.groups.map(\.name), ["快递", "餐饮"])
        let record = try XCTUnwrap(first.records.first)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(record.shipmentID, original.id)
        XCTAssertEqual(record.groupID, first.expressGroupID)
        XCTAssertEqual(record.code, original.pickupCode)
        XCTAssertEqual(record.source, original.note)
        XCTAssertEqual(record.createdAt, original.createdAt)
        XCTAssertEqual(record.updatedAt, original.updatedAt)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
        let persisted = try Data(contentsOf: dataURL)
        try JSONEncoder().encode([shipment(code: "changed")]).write(to: legacy)
        XCTAssertEqual(try store().snapshot(), first)
        XCTAssertEqual(try Data(contentsOf: dataURL), persisted)
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
    }

    func testMigrationInitializesCompletionFromEveryLegacyShipmentStatus() throws {
        let originals = ShipmentStatus.allCases.map { status -> Shipment in
            var value = shipment()
            value.id = UUID()
            value.trackingNumber = value.id.uuidString
            value.status = status
            return value
        }
        let bytes = try JSONEncoder().encode(originals)
        try bytes.write(to: legacy)
        let data = try store().snapshot()
        XCTAssertEqual(data.shipments, originals)
        for value in originals {
            let record = try XCTUnwrap(data.records.first { $0.shipmentID == value.id })
            XCTAssertEqual(record.isCompleted, value.status == .delivered || value.status == .archived)
        }
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
        XCTAssertEqual(try store().snapshot(), data)
    }

    func testLegacyBackupImportInitializesCompletionAndPreservesStandaloneHistory() throws {
        let s = try store()
        let original = try s.snapshot()
        let group = try XCTUnwrap(original.expressGroupID)
        let standalone = PickupRecord(groupID: group, code: "A-1", isCompleted: true)
        try s.transaction { $0.records.append(standalone) }
        let shipments = ShipmentStatus.allCases.map { status -> Shipment in
            var value = shipment()
            value.id = UUID()
            value.trackingNumber = value.id.uuidString
            value.status = status
            return value
        }
        let preview = try s.previewBackup(JSONEncoder().encode(shipments))
        let imported = try s.importBackup(preview, policy: nil)
        for value in shipments {
            let record = try XCTUnwrap(imported.records.first { $0.shipmentID == value.id })
            XCTAssertEqual(record.isCompleted, value.status == .delivered || value.status == .archived)
        }
        XCTAssertEqual(imported.records.first { $0.id == standalone.id }, standalone)
        XCTAssertEqual(try s.snapshot(), imported)
    }

    func testReadOnlyLegacyHistoryDoesNotCreateDirectoryLockBackupOrDataset() throws {
        var value = shipment()
        value.status = .delivered
        let bytes = try JSONEncoder().encode([value])
        try bytes.write(to: legacy)
        let history = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        let snapshot = try history.snapshot()
        XCTAssertEqual(snapshot.shipments, [value])
        XCTAssertEqual(try history.snapshot(), snapshot)
        let reopened = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        XCTAssertEqual(try reopened.snapshot(), snapshot)
        XCTAssertEqual(try reopened.exportBackup(), try history.exportBackup())
        XCTAssertTrue(try XCTUnwrap(snapshot.records.first).isCompleted)
        XCTAssertThrowsError(try history.transaction { $0.groups.removeAll() })
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testReadOnlyEmptyHistoryIsStableAndDoesNotCreateFiles() throws {
        let history = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        let first = try history.snapshot()
        let reopened = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        XCTAssertEqual(try reopened.snapshot(), first)
        XCTAssertEqual(try history.snapshot(), first)
        XCTAssertEqual(Set(first.groups.map(\.id)).count, 2)
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testReadOnlyLegacyIdentityFollowsShipmentIDNotArrayPositionOrCode() throws {
        var first = shipment()
        var second = shipment(code: "same")
        second.trackingNumber = "SECOND"
        try JSONEncoder().encode([first, second]).write(to: legacy)
        let history = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        let initial = try history.snapshot()
        first.pickupCode = "edited"
        second.note = "changed source"
        let bytes = try JSONEncoder().encode([second, first])
        try bytes.write(to: legacy)
        let reordered = try history.snapshot()
        XCTAssertEqual(reordered.groups, initial.groups)
        for shipment in [first, second] {
            let old = try XCTUnwrap(initial.records.first { $0.shipmentID == shipment.id })
            let new = try XCTUnwrap(reordered.records.first { $0.shipmentID == shipment.id })
            XCTAssertEqual(new.id, old.id)
            XCTAssertEqual(new.code, shipment.pickupCode)
            XCTAssertEqual(new.source, shipment.note)
        }
        XCTAssertEqual(Set(reordered.records.map(\.id)).count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
        // A real migration is still persisted and backed up, not a read-only projection.
        let migrated = try store().snapshot()
        XCTAssertEqual(migrated.shipments, [second, first])
        XCTAssertEqual(try Data(contentsOf: backupURL), bytes)
        XCTAssertEqual(try store().snapshot(), migrated)
        XCTAssertEqual(try history.snapshot(), migrated) // modern IDs are never rewritten
    }

    func testModernBackupAndReadOnlySnapshotPreserveExplicitCompletionChoices() throws {
        let s = try store()
        var value = shipment()
        value.status = .delivered
        let initial = try s.snapshot()
        let group = try XCTUnwrap(initial.expressGroupID)
        let restoredLinked = PickupRecord(groupID: group, code: value.pickupCode, source: value.note, isCompleted: false, shipmentID: value.id)
        let completedStandalone = PickupRecord(groupID: group, code: "history", isCompleted: true)
        try s.transaction {
            $0.shipments.append(value)
            $0.records += [restoredLinked, completedStandalone]
        }
        let expected = try s.snapshot()
        let bytes = try Data(contentsOf: dataURL)
        let readOnly = try SharedPickupStore(appGroupID: nil, legacyURL: legacy, containerURL: container, readOnly: true)
        XCTAssertEqual(try readOnly.snapshot(), expected)
        XCTAssertThrowsError(try readOnly.transaction { $0.records.removeAll() })
        XCTAssertEqual(try Data(contentsOf: dataURL), bytes)
        let fresh = try store(root.appendingPathComponent("modern-restore"))
        let restored = try fresh.importBackup(fresh.previewBackup(s.exportBackup()), policy: nil)
        XCTAssertEqual(restored.records.first { $0.id == restoredLinked.id }, restoredLinked)
        XCTAssertEqual(restored.records.first { $0.id == completedStandalone.id }, completedStandalone)
    }

    func testCorruptLegacyAndConflictingLegacyBackupNeverReplaceSource() throws {
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: legacy)
        let s = try store()
        XCTAssertThrowsError(try s.snapshot())
        XCTAssertEqual(try Data(contentsOf: legacy), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))

        let valid = try JSONEncoder().encode([shipment()])
        try valid.write(to: legacy)
        let other = Data("different backup".utf8)
        try other.write(to: backupURL)
        XCTAssertThrowsError(try s.snapshot())
        XCTAssertEqual(try Data(contentsOf: legacy), valid)
        XCTAssertEqual(try Data(contentsOf: backupURL), other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path))
    }

    func testBackupRoundTripAndConflictPoliciesAndStalePreview() throws {
        let s = try store()
        let initial = try s.snapshot()
        let bytes = try s.exportBackup()
        let fresh = try store(root.appendingPathComponent("second"))
        let preview = try fresh.previewBackup(bytes)
        XCTAssertFalse(preview.hasConflicts)
        try fresh.importBackup(preview, policy: nil)
        let restored = try fresh.snapshot()
        XCTAssertTrue(initial.groups.allSatisfy { restored.groups.contains($0) })
        XCTAssertEqual(restored.records, initial.records)
        XCTAssertEqual(restored.shipments, initial.shipments)

        var changed = initial
        changed.groups[0].name = "修改后的分组"
        let changedBytes = try JSONEncoder().encode(changed)
        let conflict = try s.previewBackup(changedBytes)
        XCTAssertTrue(conflict.hasConflicts)
        XCTAssertEqual(conflict.conflictingGroupIDs, [changed.groups[0].id])
        XCTAssertThrowsError(try s.importBackup(conflict, policy: nil))
        XCTAssertEqual(try s.snapshot(), initial)
        try s.importBackup(conflict, policy: .keepExisting)
        XCTAssertEqual(try s.snapshot(), initial)
        try s.importBackup(try s.previewBackup(changedBytes), policy: .replaceExisting)
        XCTAssertEqual(try s.snapshot(), changed)
        let stale = try s.previewBackup(bytes)
        try s.transaction { $0.groups[1].name = "并发修改" }
        let before = try s.snapshot()
        XCTAssertThrowsError(try s.importBackup(stale, policy: .replaceExisting))
        XCTAssertEqual(try s.snapshot(), before)
    }

    func testHistoricalDuplicateTrackingNumbersRoundTripIntoEmptyTarget() throws {
        var first = shipment(code: "A-1")
        first.logisticsInfo = "已到取件站"
        first.logisticsTime = Date(timeIntervalSinceReferenceDate: 5000.125)
        first.queryInfo = "查询成功"
        first.uapiCarrierCode = "test-carrier"
        first.lastQueriedAt = Date(timeIntervalSinceReferenceDate: 6000.25)
        first.lastQueryAttemptAt = Date(timeIntervalSinceReferenceDate: 7000.5)
        var second = shipment(code: "B-2")
        second.trackingNumber = " test 123 "
        second.note = "另一条历史备注"
        second.status = .archived
        second.reminderDate = Date(timeIntervalSinceReferenceDate: 8000.75)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.trackingNumber, second.trackingNumber)
        XCTAssertEqual(CarrierDetector.sanitize(first.trackingNumber), CarrierDetector.sanitize(second.trackingNumber))
        let legacyBytes = try JSONEncoder().encode([first, second])
        try legacyBytes.write(to: legacy)
        let source = try store()
        let migrated = try source.snapshot()
        XCTAssertEqual(migrated.shipments, [first, second])
        XCTAssertEqual(try Data(contentsOf: backupURL), legacyBytes)
        try source.transaction { data in
            for index in data.records.indices {
                data.records[index].location = "历史柜位-\(index)"
                // Modern backups preserve explicit choices, not just status-derived completion.
                data.records[index].isCompleted.toggle()
            }
        }
        let expected = try source.snapshot()
        let backup = try source.exportBackup()
        let policies: [BackupConflictPolicy?] = [nil, .keepExisting, .replaceExisting]
        for (index, policy) in policies.enumerated() {
            let targetURL = root.appendingPathComponent("duplicate-restore-\(index)")
            // Do not let the shared legacy fixture populate this otherwise empty target.
            let target = try SharedPickupStore(appGroupID: nil, legacyURL: targetURL.appendingPathComponent("absent.json"), containerURL: targetURL)
            let initial = try target.snapshot()
            XCTAssertTrue(initial.shipments.isEmpty)
            XCTAssertTrue(initial.records.isEmpty)
            let preview = try target.previewBackup(backup)
            XCTAssertFalse(preview.hasConflicts)
            XCTAssertEqual(preview.incoming, expected)
            let restored = try target.importBackup(preview, policy: policy)
            XCTAssertEqual(restored.shipments, expected.shipments)
            XCTAssertEqual(restored.records, expected.records)
            XCTAssertEqual(restored.groups, initial.groups + expected.groups)
            XCTAssertEqual(restored.expressGroupID, initial.expressGroupID)
            let reopened = try SharedPickupStore(appGroupID: nil, legacyURL: targetURL.appendingPathComponent("absent.json"), containerURL: targetURL)
            XCTAssertEqual(try reopened.snapshot(), restored)
            let reexported = try reopened.previewBackup(reopened.exportBackup())
            XCTAssertEqual(reexported.incoming, restored)
        }
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
        XCTAssertEqual(try source.snapshot(), expected)
    }

    func testDuplicateIncomingTrackingNumbersCannotClaimOneExistingShipmentAndRollBack() throws {
        let s = try store()
        let existing = shipment(code: "existing")
        try s.transaction { data in
            data.shipments.append(existing)
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: existing.pickupCode, source: existing.note, shipmentID: existing.id))
        }
        let before = try s.snapshot()
        let diskBefore = try Data(contentsOf: dataURL)
        var first = shipment(code: "incoming-1")
        first.trackingNumber = "test 123"
        let second = shipment(code: "incoming-2")
        let preview = try s.previewBackup(JSONEncoder().encode([first, second]))
        XCTAssertTrue(preview.hasConflicts)
        XCTAssertEqual(preview.incoming.shipments.count, 2)
        for policy in [BackupConflictPolicy.keepExisting, .replaceExisting] {
            XCTAssertThrowsError(try s.importBackup(preview, policy: policy)) { error in
                guard case PickupStorageError.invalidData(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(message, "多个备份运单匹配同一现有运单，无法安全合并")
            }
            XCTAssertEqual(try Data(contentsOf: dataURL), diskBefore)
            XCTAssertEqual(try s.snapshot(), before)
        }
    }

    func testIncomingShipmentCannotChooseBetweenHistoricalDuplicatesAndRollsBack() throws {
        let s = try store()
        let first = shipment(code: "existing-1")
        var second = shipment(code: "existing-2")
        second.trackingNumber = "test 123"
        try s.transaction { data in
            for value in [first, second] {
                data.shipments.append(value)
                data.records.append(PickupRecord(groupID: data.groups[0].id, code: value.pickupCode, source: value.note, shipmentID: value.id))
            }
        }
        let before = try s.snapshot()
        let diskBefore = try Data(contentsOf: dataURL)
        // Even an exact UUID match must not guess which duplicate to keep or replace.
        let preview = try s.previewBackup(JSONEncoder().encode([first]))
        XCTAssertTrue(preview.hasConflicts)
        for policy in [BackupConflictPolicy.keepExisting, .replaceExisting] {
            XCTAssertThrowsError(try s.importBackup(preview, policy: policy)) { error in
                guard case PickupStorageError.invalidData(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(message, "运单 ID 与运单号发生多重冲突，无法安全合并")
            }
            XCTAssertEqual(try Data(contentsOf: dataURL), diskBefore)
            XCTAssertEqual(try s.snapshot(), before)
        }
    }

    func testEmptyCodeShipmentAndStandaloneFoodWithSameCode() throws {
        let s = try store()
        let express = shipment(code: "")
        try s.transaction { data in
            let food = try XCTUnwrap(data.groups.first { $0.name == "餐饮" })
            let group = try XCTUnwrap(data.expressGroupID)
            data.shipments.append(express)
            data.records.append(PickupRecord(groupID: group, code: "", source: express.note, shipmentID: express.id))
            data.records.append(PickupRecord(groupID: food.id, code: "42", source: "店一"))
            data.records.append(PickupRecord(groupID: food.id, code: "42", source: "店二"))
        }
        let saved = try store().snapshot()
        XCTAssertEqual(saved.shipments, [express])
        XCTAssertEqual(saved.records.filter { $0.shipmentID == express.id }.map(\.code), [""])
        let food = saved.records.filter { $0.shipmentID == nil }
        XCTAssertEqual(food.count, 2)
        XCTAssertEqual(Set(food.map(\.id)).count, 2)
        XCTAssertEqual(food.map(\.code), ["42", "42"])
        let before = saved
        XCTAssertThrowsError(try s.transaction { data in
            data.records.append(PickupRecord(groupID: data.groups[0].id, code: " "))
        })
        XCTAssertEqual(try s.snapshot(), before)
    }

    func testConcurrentTransactionsDoNotLoseUpdatesAndInvalidMutationRollsBack() throws {
        let s = try store()
        let groupID = try XCTUnwrap(s.snapshot().expressGroupID)
        let workers = 40
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: workers) { index in
            do {
                let instance = try self.store()
                try instance.transaction { data in
                    data.records.append(PickupRecord(groupID: groupID, code: "code-\(index)"))
                }
            } catch {
                lock.lock(); failures.append(String(describing: error)); lock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        let result = try s.snapshot()
        XCTAssertEqual(result.records.count, workers)
        XCTAssertEqual(Set(result.records.map(\.code)), Set((0..<workers).map { "code-\($0)" }))
        XCTAssertThrowsError(try s.transaction { data in
            data.records.append(PickupRecord(groupID: UUID(), code: "invalid"))
        })
        XCTAssertEqual(try s.snapshot(), result)
    }
    func testImportDefaultPreservesExistingAndFillsMissing() throws {
        let source = try store(root.appendingPathComponent("source"))
        let backup = try source.exportBackup()
        let sourceDefault = try source.snapshot().expressGroupID
        let destination = try store()
        let original = try destination.snapshot().expressGroupID
        let committed = try destination.importBackup(destination.previewBackup(backup), policy: .replaceExisting)
        XCTAssertEqual(committed.expressGroupID, original)
        XCTAssertEqual(try destination.snapshot().expressGroupID, original)
        try destination.transaction { $0.expressGroupID = nil }
        let restored = try destination.importBackup(destination.previewBackup(backup), policy: .keepExisting)
        XCTAssertEqual(restored.expressGroupID, sourceDefault)
        XCTAssertEqual(try destination.snapshot().expressGroupID, sourceDefault)
    }

    func testExtensionRequiresInitializedDataForReadsAndWrites() throws {
        let legacyBytes = try JSONEncoder().encode([shipment()])
        try legacyBytes.write(to: legacy)
        let extensionStore = try SharedPickupStore(appGroupID: nil, legacyURL: legacy,
                                                   containerURL: container, accessMode: .existingSharedData)
        func assertRequiresMainApp(_ action: () throws -> Void) {
            XCTAssertThrowsError(try action()) { error in
                guard case PickupStorageError.requiresMainApp = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        assertRequiresMainApp { _ = try extensionStore.snapshot() }
        assertRequiresMainApp { try extensionStore.transaction { _ in XCTFail("Mutation must not run") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)

        let app = try store()
        let initialized = try app.snapshot()
        XCTAssertEqual(try extensionStore.snapshot(), initialized)
        try extensionStore.transaction { $0.groups[0].name = "扩展修改" }
        XCTAssertEqual(try app.snapshot().groups[0].name, "扩展修改")
        try FileManager.default.removeItem(at: dataURL)
        assertRequiresMainApp { _ = try extensionStore.snapshot() }
        assertRequiresMainApp { try extensionStore.transaction { _ in XCTFail("Mutation must not run") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataURL.path))
    }

    func testExtensionDoesNotRebuildCorruptSharedData() throws {
        let app = try store()
        _ = try app.snapshot()
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: dataURL)
        let extensionStore = try SharedPickupStore(appGroupID: nil, legacyURL: legacy,
                                                   containerURL: container, accessMode: .existingSharedData)
        XCTAssertThrowsError(try extensionStore.snapshot())
        XCTAssertThrowsError(try extensionStore.transaction { _ in XCTFail("Mutation must not run") })
        XCTAssertThrowsError(try app.snapshot())
        XCTAssertEqual(try Data(contentsOf: dataURL), corrupt)
    }

}
