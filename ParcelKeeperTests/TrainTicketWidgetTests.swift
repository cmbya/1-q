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

    func testMissingArrivalCannotDisplayOrInventExpiry() {
        let first = ticket(id: firstID, arrivalDate: "", arrival: "")
        XCTAssertNil(first.fields.arrival)
        for now in [instant("2026-10-31T14:00:00Z"), instant("2026-11-03T00:00:00Z")] {
            XCTAssertTrue(TrainTicketSelection.eligibleTickets(in: [first], now: now).isEmpty)
            XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: automatic, now: now))
            XCTAssertNil(TrainTicketSelection.ticket(in: [first],
                binding: TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID), now: now))
        }
    }

    func testFixedEmptyOrMissingIDNeverFallsBackToAutomatic() {
        let first = ticket(id: firstID)
        let now = instant("2026-10-31T14:00:00Z")
        XCTAssertNil(TrainTicketSelection.ticket(in: [first],
            binding: TrainWidgetBinding(slot: .b, mode: .fixed), now: now))
        XCTAssertNil(TrainTicketSelection.ticket(in: [first],
            binding: TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: secondID), now: now))
    }

    func testFixedHidesAtExactEndWithoutFallingBackAndRejectsArchivedOrEnded() {
        var first = ticket(id: firstID)
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        let binding = TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID)
        let before = instant("2026-10-31T20:59:59Z")
        XCTAssertEqual(TrainTicketSelection.ticket(in: [first, second], binding: binding, now: before)?.id, firstID)
        XCTAssertNil(TrainTicketSelection.ticket(in: [first, second], binding: binding,
            now: instant("2026-10-31T21:00:00Z")))
        first.isArchived = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: binding, now: before))
        first.isArchived = false
        first.isEnded = true
        XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: binding, now: before))
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

    func testKeepVisibleDoesNotBypassEndOrExplicitEndOrArchive() {
        var first = ticket(id: firstID)
        first.keepVisible = true
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        let now = instant("2026-10-31T21:00:00Z")
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, secondID)
        first.isEnded = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, secondID)
        first.isEnded = false
        first.isArchived = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: automatic, now: now)?.id, secondID)
    }

    func testLegacyWindowStartsAtShanghaiMidnightForAutomaticAndFixed() {
        let first = ticket(id: firstID)
        let start = instant("2026-10-30T16:00:00Z")
        XCTAssertEqual(first.widgetStartsAt, start)
        XCTAssertEqual(first.widgetEndsAt, instant("2026-10-31T21:00:00Z"))
        for binding in [automatic, TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID)] {
            XCTAssertNil(TrainTicketSelection.ticket(in: [first], binding: binding, now: start.addingTimeInterval(-1)))
            XCTAssertEqual(TrainTicketSelection.ticket(in: [first], binding: binding, now: start)?.id, firstID)
        }
    }

    func testProductionTimelineDatesRevealAtStartAndHideAtEndInBothModes() {
        let first = ticket(id: firstID, date: "2026-11-01", departure: "01:00", arrival: "04:00")
        let now = instant("2026-10-31T15:00:00Z")
        let start = instant("2026-10-31T16:00:00Z")
        let end = instant("2026-10-31T20:00:00Z")
        // This is the exact API called by TrainTicketProvider, not a test-side date builder.
        let dates = TrainTicketSelection.timelineDates(in: [first], now: now)
        XCTAssertEqual(dates, [now, start, end])
        for binding in [automatic, TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID)] {
            let displayed = dates.map { TrainTicketSelection.ticket(in: [first], binding: binding, now: $0)?.id }
            XCTAssertEqual(displayed, [nil, firstID, nil])
        }
        XCTAssertEqual(TrainTicketSelection.timelineDates(in: [first], now: end), [end])
    }

    func testProductionTimelineDatesDeduplicateAndRespect24HourHorizon() {
        let first = ticket(id: firstID, date: "2026-11-01", departure: "01:00", arrival: "04:00")
        let duplicateWindow = ticket(id: secondID, date: "2026-11-01", departure: "02:00", arrival: "04:00")
        let beyond = ticket(id: UUID(), date: "2026-11-03", departure: "01:00", arrivalDate: "2026-11-03", arrival: "04:00")
        let now = instant("2026-10-31T15:00:00Z")
        XCTAssertEqual(TrainTicketSelection.timelineDates(in: [beyond, duplicateWindow, first], now: now),
                       [now, instant("2026-10-31T16:00:00Z"), instant("2026-10-31T20:00:00Z")])
        // The start exactly at now + 24h is included; dates after that are omitted.
        let horizonNow = instant("2026-10-30T16:00:00Z")
        XCTAssertEqual(TrainTicketSelection.timelineDates(in: [first], now: horizonNow),
                       [horizonNow, instant("2026-10-31T16:00:00Z")])
        XCTAssertEqual(TrainTicketSelection.timelineDates(in: [], now: now), [now])
    }

    func testProductionTimelineUsesExplicitWindowAndOmitsDisabledArchivedEndedTickets() {
        let now = instant("2026-10-31T12:00:00Z")
        let start = instant("2026-10-31T13:00:00Z")
        let end = instant("2026-10-31T14:00:00Z")
        var custom = ticket(id: firstID)
        custom.displayWindow = TrainTicketDisplayWindow(enabled: true, startsAt: start, endsAt: end)
        var disabled = ticket(id: UUID())
        disabled.displayWindow = TrainTicketDisplayWindow(enabled: false,
            startsAt: now.addingTimeInterval(60), endsAt: now.addingTimeInterval(120))
        var archived = ticket(id: UUID())
        archived.isArchived = true
        var ended = ticket(id: UUID())
        ended.isEnded = true
        let tickets = [disabled, archived, ended, custom]
        let dates = TrainTicketSelection.timelineDates(in: tickets, now: now)
        XCTAssertEqual(dates, [now, start, end])
        for binding in [automatic, TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: firstID)] {
            XCTAssertEqual(dates.map { TrainTicketSelection.ticket(in: tickets, binding: binding, now: $0)?.id },
                           [nil, firstID, nil])
        }
    }

    func testProductionTimelineDatesCapIncludesNowAndKeepsEarliestBoundaries() {
        let tickets = (0..<60).map { index in
            ticket(id: UUID(), date: "2026-11-01", departure: "00:00", arrival: String(format: "%02d:%02d", index / 60 + 1, index % 60))
        }
        let now = instant("2026-10-31T15:00:00Z")
        let dates = TrainTicketSelection.timelineDates(in: tickets, now: now)
        XCTAssertEqual(dates.count, 40)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, Array(Set(dates)).sorted())
        XCTAssertEqual(dates[1], instant("2026-10-31T16:00:00Z"))
        XCTAssertEqual(dates.last, instant("2026-10-31T17:37:00Z"))
    }

    func testFourSameTrainDifferentSeatsRemainEligibleAndIndividuallyBrowsable() {
        let ids = (1...4).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))! }
        let tickets = ids.enumerated().map { index, id -> TrainTicket in
            var result = ticket(id: id)
            result.fields.seat = ["08A", "08B", "08C", "08F"][index]
            return result
        }
        let now = instant("2026-10-31T16:00:00Z")
        let eligible = TrainTicketSelection.eligibleTickets(in: Array(tickets.reversed()), now: now)
        XCTAssertEqual(eligible.map(\.id), ids)
        XCTAssertEqual(Set(eligible.map { $0.fields.seat }).count, 4)
        for id in ids {
            let binding = TrainWidgetBinding(slot: .a, mode: .automatic, browsingTicketID: id)
            XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: binding, now: now)?.id, id)
        }
        let stale = TrainWidgetBinding(slot: .a, mode: .automatic, browsingTicketID: UUID())
        XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: stale, now: now)?.id, ids[0])
        XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: automatic, now: now)?.id, ids[0])
    }

    func testBrowsingCannotKeepExpiredOrArchivedTicketOnScreen() {
        var first = ticket(id: firstID)
        let second = ticket(id: secondID, date: "2026-11-01", departure: "08:00", arrival: "12:00")
        let binding = TrainWidgetBinding(slot: .a, mode: .automatic, browsingTicketID: firstID)
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: binding,
            now: instant("2026-10-31T21:00:00Z"))?.id, secondID)
        first.isArchived = true
        XCTAssertEqual(TrainTicketSelection.ticket(in: [second, first], binding: binding,
            now: instant("2026-10-31T20:00:00Z"))?.id, secondID)
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
