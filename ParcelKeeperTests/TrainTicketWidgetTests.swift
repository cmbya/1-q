import XCTest
@testable import ParcelKeeper

final class TrainTicketWidgetTests: XCTestCase {
    private let automatic = TrainWidgetBinding(slot: .a, mode: .automatic)
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func instant(_ value: String) -> Date {
        // Explicit UTC fixtures verify that model dates use Shanghai, not host timezone.
        ISO8601DateFormatter().date(from: value)!
    }

    private func ticket(id: UUID, date: String = "2026-10-31", departure: String = "23:00",
                        arrivalDate: String = "2026-11-01", arrival: String = "05:00") -> TrainTicket {
        TrainTicket(id: id, fields: TrainTicketFields(
            departureDate: date, trainNumber: "G123", departureStation: "北京南",
            departureTime: departure, arrivalStation: "上海虹桥", arrivalDate: arrivalDate,
            arrivalTime: arrival, carriage: "03", seat: "08A", seatClass: "二等座", gate: "A12", passenger: "张三"))
    }

    func testAutomaticRetainsInProgressTicketUntilExactArrivalThenSwitches() {
        let first = ticket(id: firstID)
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        let tickets = [second, first]
        for now in [instant("2026-10-31T14:59:59Z"), instant("2026-10-31T15:00:00Z"),
                    instant("2026-10-31T20:59:59Z")] {
            XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: automatic, now: now)?.id, firstID)
        }
        XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: automatic,
            now: instant("2026-10-31T21:00:00Z"))?.id, secondID)
        XCTAssertNil(TrainTicketSelection.ticket(in: tickets, binding: automatic,
            now: instant("2026-11-01T04:00:00Z")))
    }

    func testMissingArrivalDoesNotInventDepartureBasedExpiry() {
        let first = ticket(id: firstID, arrivalDate: "", arrival: "")
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        XCTAssertNil(first.fields.arrival)
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic,
            now: instant("2026-11-03T00:00:00Z"))?.id, firstID)
    }

    func testFixedEmptyOrMissingIDNeverFallsBackToAutomatic() {
        let first = ticket(id: firstID)
        let now = instant("2026-10-31T14:00:00Z")
        XCTAssertNil(TrainTicketSelection.ticket(in: [first],
            binding: TrainWidgetBinding(slot: .b, mode: .fixed), now: now))
        XCTAssertNil(TrainTicketSelection.ticket(in: [first],
            binding: TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: secondID), now: now))
    }

    func testFixedRetainsArrivedTicketButRejectsArchivedOrEnded() {
        var first = ticket(id: firstID)
        let binding = TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID)
        let now = instant("2026-11-02T00:00:00Z")
        XCTAssertEqual(TrainTicketSelection.ticket(in: [first], binding: binding, now: now)?.id, firstID)
        first.isArchived = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: binding, now: now))
        first.isArchived = false
        first.isEnded = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: binding, now: now))
    }

    func testCrossYearArrivalUsesFullDateAndShanghaiTimeZone() {
        let first = ticket(id: firstID, date: "2026-12-31", departure: "23:50",
                           arrivalDate: "2027-01-01", arrival: "00:10")
        XCTAssertEqual(first.fields.departure, instant("2026-12-31T15:50:00Z"))
        XCTAssertEqual(first.fields.arrival, instant("2026-12-31T16:10:00Z"))
        XCTAssertNotNil(TrainTicketSelection.ticket(in: [first], binding: automatic,
            now: instant("2026-12-31T16:09:59Z")))
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: automatic,
            now: instant("2026-12-31T16:10:00Z")))
    }

    func testEqualDepartureTieBreakIsStableRegardlessOfInputOrderOrCreationDate() {
        var first = ticket(id: firstID)
        var second = ticket(id: secondID)
        first.createdAt = instant("2026-10-30T00:00:00Z")
        second.createdAt = instant("2026-10-29T00:00:00Z")
        let now = instant("2026-10-31T16:00:00Z")
        for tickets in [[first, second], [second, first]] {
            XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: automatic, now: now)?.id, firstID)
        }
    }

    func testKeepVisibleSurvivesArrivalButNotExplicitEndOrArchive() {
        var first = ticket(id: firstID)
        first.keepVisible = true
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        let now = instant("2026-10-31T21:00:00Z")
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, firstID)
        first.isEnded = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, secondID)
        first.isEnded = false
        first.isArchived = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, secondID)
    }

    func testSlotDefaultsAndKindsStayIndependent() {
        let a = TrainTicketSelection.binding(for: .a, in: [])
        let b = TrainTicketSelection.binding(for: .b, in: [])
        XCTAssertEqual(a.mode, .automatic)
        XCTAssertEqual(b.mode, .fixed)
        XCTAssertNil(b.ticketID)
        XCTAssertEqual(TrainWidgetSlot.a.kind, "ParcelKeeperTrainA")
        XCTAssertEqual(TrainWidgetSlot.b.kind, "ParcelKeeperTrainB")
        let custom = TrainWidgetBinding(slot: .a, mode: .fixed, ticketID: firstID)
        XCTAssertEqual(TrainTicketSelection.binding(for: .a, in: [custom]), custom)
        XCTAssertEqual(TrainTicketSelection.binding(for: .b, in: [custom]), b)
    }
}
