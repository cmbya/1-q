import XCTest
@testable import ParcelKeeper

@MainActor
final class TrainTicketStoreTests: XCTestCase {
    private func fields() -> TrainTicketFields {
        TrainTicketFields(departureDate: "2026-10-31", trainNumber: "G123", departureStation: "北京南", departureTime: "23:00", arrivalStation: "上海虹桥", arrivalDate: "2026-11-01", arrivalTime: "05:00", carriage: "03", seat: "08A", passenger: "张三")
    }
    private func fixture() throws -> (URL, SharedPickupStore, ShipmentStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("absent"), containerURL: root)
        return (root, shared, ShipmentStore(storageProvider: { shared }))
    }
    func testStrictDatesTimesTrimmingAndPairedArrival() throws {
        var value = fields()
        value.trainNumber = " G123\n"
        XCTAssertEqual(try value.validated().trainNumber, "G123")
        XCTAssertEqual(value.departure, ISO8601DateFormatter().date(from: "2026-10-31T15:00:00Z"))
        for date in ["2026-02-29", "2026-11-31", "2026-1-01", "2026-10-31junk"] {
            value = fields(); value.departureDate = date
            XCTAssertThrowsError(try value.validated())
        }
        for time in ["24:00", "9:00", "12:60", "23:00junk"] {
            value = fields(); value.departureTime = time
            XCTAssertThrowsError(try value.validated())
        }
        value = fields(); value.arrivalDate = ""
        XCTAssertThrowsError(try value.validated())
        value.arrivalTime = ""
        XCTAssertNoThrow(try value.validated())
        XCTAssertNil(value.arrival)
        value = fields(); value.arrivalDate = value.departureDate; value.arrivalTime = "22:00"
        XCTAssertThrowsError(try value.validated())
        value = fields(); value.departureStation = "\u{FFFD}"
        XCTAssertThrowsError(try value.validated())
        value = fields(); value.seat = String(repeating: "A", count: 300)
        XCTAssertThrowsError(try value.validated())
        value = fields(); value.departureStation = " "
        XCTAssertThrowsError(try value.validated())
    }
    func testSelectionUsesArrivalNotDepartureAndStableIDs() throws {
        let value = fields()
        var first = TrainTicket(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, fields: value)
        let second = TrainTicket(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, fields: value)
        let auto = TrainWidgetBinding(slot: .a, mode: .automatic)
        let during = try XCTUnwrap(value.departure).addingTimeInterval(60)
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: auto, now: during)?.id, first.id)
        let end = try XCTUnwrap(value.arrival)
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: auto, now: end))
        first.keepVisible = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [first], binding: auto, now: end)?.id, first.id)
        first.isEnded = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: auto, now: during))
        first.isEnded = false; first.keepVisible = false
        let fixed = TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: first.id)
        XCTAssertEqual(TrainTicketSelection.ticket(in: [first], binding: fixed, now: end)?.id, first.id)
        first.isArchived = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: fixed, now: during))
        first.isArchived = false; first.fields.arrivalDate = ""; first.fields.arrivalTime = ""
        XCTAssertNotNil(TrainTicketSelection.ticket(in: [first], binding: auto, now: end))
        XCTAssertEqual(TrainTicketSelection.binding(for: .a, in: []).mode, .automatic)
        XCTAssertEqual(TrainTicketSelection.binding(for: .b, in: []).mode, .fixed)
        XCTAssertNil(TrainTicketSelection.binding(for: .b, in: []).ticketID)
    }
    func testCRUDRejectsStaleSnapshotsAndPreservesIdentity() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try app.saveTrainTicket(fields())
        let original = try XCTUnwrap(app.trainTickets.first)
        var changed = fields(); changed.gate = "A2"
        XCTAssertEqual(try app.saveTrainTicket(changed, existing: original), id)
        let latest = try XCTUnwrap(app.trainTickets.first)
        XCTAssertEqual(latest.createdAt, original.createdAt)
        let before = try shared.snapshot()
        XCTAssertThrowsError(try app.saveTrainTicket(fields(), existing: original))
        XCTAssertThrowsError(try app.deleteTrainTicket(id: id, expected: original))
        XCTAssertThrowsError(try app.setTrainTicketArchived(original, archived: true))
        XCTAssertEqual(try shared.snapshot(), before)
        try app.setTrainTicketArchived(latest, archived: true)
        try app.setTrainTicketEnded(try XCTUnwrap(app.trainTickets.first), ended: true)
        try app.setTrainTicketKeepVisible(try XCTUnwrap(app.trainTickets.first), keepVisible: true)
        let binding = TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: id)
        try app.setTrainWidgetBinding(binding)
        XCTAssertEqual(try shared.snapshot().trainWidgetBindings, [binding])
        try app.deleteTrainTicket(id: id, expected: try XCTUnwrap(app.trainTickets.first))
        XCTAssertTrue(app.trainTickets.isEmpty)
        XCTAssertNil(app.trainWidgetBindings.first?.ticketID)
    }
    func testDuplicatesAreCheckedOnlyForNewIdentityAndHistoricalDuplicatesRemainWritable() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try app.saveTrainTicket(fields())
        var duplicate = fields(); duplicate.gate = "different"
        XCTAssertThrowsError(try app.saveTrainTicket(duplicate))
        try shared.transaction { $0.trainTickets?.append(TrainTicket(fields: self.fields())) }
        try app.reload()
        let ticket = try XCTUnwrap(app.trainTickets.first)
        _ = try app.saveTrainTicket(duplicate, existing: ticket)
        _ = try app.createGroup(name: "unrelated")
        XCTAssertEqual(try shared.snapshot().trainTickets?.count, 2)
    }
    func testOldJSONAndBackupMergeByTicketIDAndBindingSlot() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try shared.exportBackup()
        XCTAssertNil(try JSONDecoder().decode(PickupDataset.self, from: old).trainTickets)
        let id = try app.saveTrainTicket(fields())
        try app.setTrainWidgetBinding(TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: id))
        let saved = try shared.snapshot()
        _ = try shared.importBackup(shared.previewBackup(old), policy: .replaceExisting)
        XCTAssertEqual(try shared.snapshot().trainTickets, saved.trainTickets)
        XCTAssertEqual(try shared.snapshot().trainWidgetBindings, saved.trainWidgetBindings)
        var incoming = saved
        incoming.trainTickets?[0].fields.gate = "A9"
        incoming.trainWidgetBindings = [TrainWidgetBinding(slot: .b, mode: .automatic)]
        let bytes = try JSONEncoder().encode(incoming)
        var preview = try shared.previewBackup(bytes)
        XCTAssertEqual(preview.conflictingTrainTicketIDs, [id])
        XCTAssertEqual(preview.conflictingTrainWidgetSlots, [.b])
        XCTAssertTrue(preview.hasConflicts)
        XCTAssertThrowsError(try shared.importBackup(preview, policy: nil))
        _ = try shared.importBackup(preview, policy: .keepExisting)
        XCTAssertEqual(try shared.snapshot().trainTickets, saved.trainTickets)
        preview = try shared.previewBackup(bytes)
        _ = try shared.importBackup(preview, policy: .replaceExisting)
        XCTAssertEqual(try shared.snapshot().trainTickets, incoming.trainTickets)
        XCTAssertEqual(try shared.snapshot().trainWidgetBindings, incoming.trainWidgetBindings)
        let roundTrip = try JSONDecoder().decode(PickupDataset.self, from: shared.exportBackup())
        XCTAssertEqual(roundTrip, try shared.snapshot())
    }
    func testConcurrentStoresUseLockedLatestDataAndRejectStaleStateChanges() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let otherShared = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("absent"), containerURL: root)
        let other = ShipmentStore(storageProvider: { otherShared })
        let id = try app.saveTrainTicket(fields())
        XCTAssertThrowsError(try other.saveTrainTicket(fields()))
        try other.reload()
        let original = try XCTUnwrap(other.trainTickets.first)
        try app.setTrainTicketEnded(try XCTUnwrap(app.trainTickets.first), ended: true)
        let before = try shared.snapshot()
        XCTAssertThrowsError(try other.setTrainTicketKeepVisible(original, keepVisible: true))
        XCTAssertThrowsError(try other.setTrainTicketEnded(original, ended: false))
        XCTAssertThrowsError(try other.deleteTrainTicket(id: id, expected: original))
        XCTAssertEqual(try shared.snapshot(), before)
        try other.reload()
        try other.setTrainTicketEnded(try XCTUnwrap(other.trainTickets.first), ended: false)
        var distinct = fields(); distinct.passenger = "李四"
        _ = try other.saveTrainTicket(distinct)
        try app.reload()
        XCTAssertEqual(app.trainTickets.count, 2)
    }

    func testBackupRetainsHistoricalDuplicateTicketsAndRejectsStalePreview() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try app.saveTrainTicket(fields())
        var incoming = try shared.snapshot()
        incoming.trainTickets?.append(TrainTicket(fields: fields()))
        let preview = try shared.previewBackup(JSONEncoder().encode(incoming))
        _ = try shared.importBackup(preview, policy: nil)
        XCTAssertEqual(try shared.snapshot().trainTickets?.count, 2)
        let stale = try shared.previewBackup(shared.exportBackup())
        _ = try app.createGroup(name: "改变预览基线")
        XCTAssertThrowsError(try shared.importBackup(stale, policy: .replaceExisting))
        let freshRoot = root.appendingPathComponent("fresh")
        let fresh = try SharedPickupStore(appGroupID: nil, legacyURL: freshRoot.appendingPathComponent("absent"), containerURL: freshRoot)
        _ = try fresh.importBackup(fresh.previewBackup(shared.exportBackup()), policy: nil)
        XCTAssertEqual(try fresh.snapshot().trainTickets?.count, 2)
    }

    func testWidgetBindingChecksExpectedValueInsideTransaction() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = TrainTicketSelection.binding(for: .a, in: [])
        let changed = TrainWidgetBinding(slot: .a, mode: .fixed)
        try shared.transaction { $0.trainWidgetBindings = [changed] }
        XCTAssertThrowsError(try app.setTrainWidgetBinding(baseline, expected: baseline))
        XCTAssertEqual(try shared.snapshot().trainWidgetBindings, [changed])
    }
    func testInvalidSharedDataAndReadOnlyWritesDoNotMutate() throws {
        let (root, shared, app) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try app.saveTrainTicket(fields())
        let before = try shared.snapshot()
        let duplicate = try XCTUnwrap(before.trainTickets?.first)
        XCTAssertThrowsError(try shared.transaction { $0.trainTickets?.append(duplicate) })
        XCTAssertThrowsError(try shared.transaction { $0.trainWidgetBindings = [TrainWidgetBinding(slot: .a, mode: .automatic), TrainWidgetBinding(slot: .a, mode: .fixed)] })
        XCTAssertThrowsError(try app.setTrainWidgetBinding(TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: UUID())))
        XCTAssertEqual(try shared.snapshot(), before)
        let readOnly = try SharedPickupStore(appGroupID: nil, legacyURL: root.appendingPathComponent("absent"), containerURL: root, readOnly: true)
        let blocked = ShipmentStore(storageProvider: { readOnly })
        XCTAssertThrowsError(try blocked.saveTrainTicket(fields()))
        XCTAssertThrowsError(try blocked.deleteTrainTicket(id: id, expected: try XCTUnwrap(blocked.trainTickets.first)))
        XCTAssertEqual(try shared.snapshot(), before)
    }
}
