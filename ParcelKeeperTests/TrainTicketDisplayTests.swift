import XCTest
@testable import ParcelKeeper

final class TrainTicketDisplayTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func ticket() -> TrainTicket {
        TrainTicket(fields: TrainTicketFields(departureDate: "2026-10-31", trainNumber: "G123", departureStation: "北京南", departureTime: "23:00", arrivalStation: "上海虹桥", arrivalDate: "2026-11-01", arrivalTime: "05:00"))
    }
    func testLegacyWindowIsShanghaiDepartureDayUntilArrival() throws {
        var value = ticket()
        let start = date("2026-10-30T16:00:00Z")
        let end = date("2026-10-31T21:00:00Z")
        XCTAssertEqual(value.widgetStartsAt, start)
        XCTAssertEqual(value.widgetEndsAt, end)
        XCTAssertFalse(value.isWidgetVisible(at: start.addingTimeInterval(-1)))
        XCTAssertTrue(value.isWidgetVisible(at: start))
        XCTAssertTrue(value.isWidgetVisible(at: end.addingTimeInterval(-1)))
        value.keepVisible = true
        XCTAssertFalse(value.isWidgetVisible(at: end))
        XCTAssertFalse(value.isEnded)
        value.fields.arrivalDate = ""; value.fields.arrivalTime = ""
        XCTAssertNoThrow(try value.validatedDisplayWindow())
        XCTAssertFalse(value.isWidgetVisible(at: start))
        let decoded = try JSONDecoder().decode(TrainTicket.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.displayWindow)
        let binding = TrainWidgetBinding(slot: .a, mode: .automatic)
        XCTAssertNil(try JSONDecoder().decode(TrainWidgetBinding.self, from: JSONEncoder().encode(binding)).browsingTicketID)
    }
    func testExplicitWindowValidationAndStatePrecedence() throws {
        var value = ticket()
        let start = date("2026-10-31T12:00:00Z")
        let end = date("2026-11-02T12:00:00Z")
        value.displayWindow = TrainTicketDisplayWindow(startsAt: start, endsAt: end)
        XCTAssertNoThrow(try value.validatedDisplayWindow())
        XCTAssertTrue(value.isWidgetVisible(at: start))
        XCTAssertTrue(value.isWidgetVisible(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(value.isWidgetVisible(at: end))
        value.isArchived = true
        XCTAssertFalse(value.isWidgetVisible(at: start))
        value.isArchived = false; value.isEnded = true
        XCTAssertFalse(value.isWidgetVisible(at: start))
        value.isEnded = false
        for window in [TrainTicketDisplayWindow(), TrainTicketDisplayWindow(startsAt: end),
                       TrainTicketDisplayWindow(startsAt: start, endsAt: start),
                       TrainTicketDisplayWindow(startsAt: end, endsAt: start),
                       TrainTicketDisplayWindow(startsAt: Date(timeIntervalSinceReferenceDate: .infinity), endsAt: end),
                       TrainTicketDisplayWindow(startsAt: start, endsAt: Date(timeIntervalSinceReferenceDate: .nan))] {
            value.displayWindow = window
            XCTAssertThrowsError(try value.validatedDisplayWindow())
            XCTAssertFalse(value.isWidgetVisible(at: start))
        }
        value.displayWindow = TrainTicketDisplayWindow(startsAt: start)
        XCTAssertNoThrow(try value.validatedDisplayWindow())
        XCTAssertEqual(value.widgetEndsAt, value.fields.arrival)
        value.displayWindow = TrainTicketDisplayWindow(enabled: false)
        XCTAssertNoThrow(try value.validatedDisplayWindow())
        XCTAssertFalse(value.isWidgetVisible(at: start))
    }
    func testSelectionBrowsingExpiryFixedAndStableOrder() {
        var first = ticket(), second = ticket()
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let now = date("2026-10-31T12:00:00Z")
        second.displayWindow = TrainTicketDisplayWindow(startsAt: now, endsAt: now.addingTimeInterval(60))
        let tickets = [second, first]
        XCTAssertEqual(TrainTicketSelection.eligibleTickets(in: tickets, now: now).map(\.id), [first.id, second.id])
        let browsing = TrainWidgetBinding(slot: .a, mode: .automatic, browsingTicketID: second.id)
        XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: browsing, now: now)?.id, second.id)
        XCTAssertEqual(TrainTicketSelection.ticket(in: tickets, binding: browsing, now: now.addingTimeInterval(60))?.id, first.id)
        let fixed = TrainWidgetBinding(slot: .b, mode: .fixed, ticketID: second.id)
        XCTAssertNil(TrainTicketSelection.ticket(in: tickets, binding: fixed, now: now.addingTimeInterval(60)))
        XCTAssertNil(TrainTicketSelection.ticket(in: tickets, binding: TrainWidgetBinding(slot: .b, mode: .fixed), now: now))
    }
    func testTimelineIncludesStartsEndsDeduplicatesAndCapsFortyIncludingNow() {
        let now = date("2026-10-31T00:00:00Z")
        let tickets = (1...50).map { offset -> TrainTicket in
            var value = ticket()
            value.displayWindow = TrainTicketDisplayWindow(startsAt: now.addingTimeInterval(Double(offset * 60)), endsAt: now.addingTimeInterval(Double(offset * 60 + 30)))
            return value
        }
        let dates = TrainTicketSelection.timelineDates(in: tickets + tickets, now: now)
        XCTAssertEqual(dates.count, 40)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(dates[1], now.addingTimeInterval(60))
        XCTAssertEqual(dates[2], now.addingTimeInterval(90))
        var outside = ticket()
        outside.displayWindow = TrainTicketDisplayWindow(startsAt: now.addingTimeInterval(86401), endsAt: now.addingTimeInterval(90000))
        XCTAssertEqual(TrainTicketSelection.timelineDates(in: [outside], now: now), [now])
    }
}
