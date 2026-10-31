import Foundation

struct TrainTicketFields: Codable, Equatable {
    var departureDate: String = ""
    var trainNumber: String = ""
    var departureStation: String = ""
    var departureTime: String = ""
    var arrivalStation: String = ""
    var arrivalDate: String = ""
    var arrivalTime: String = ""
    var carriage: String = ""
    var seat: String = ""
    var seatClass: String = ""
    var gate: String = ""
    var passenger: String = ""

    // POSIX locale, Gregorian calendar and Shanghai timezone are independent of device settings.
    private static func date(_ day: String, _ time: String) -> Date? {
        guard day.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              time.range(of: #"^[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil,
              !day.hasPrefix("0000") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        let text = day + " " + time
        guard let result = formatter.date(from: text), formatter.string(from: result) == text else { return nil }
        return result
    }
    var departure: Date? { Self.date(departureDate, departureTime) }
    var arrival: Date? { Self.date(arrivalDate, arrivalTime) }

    func validated() throws -> TrainTicketFields {
        var result = self
        let limits: [(WritableKeyPath<TrainTicketFields, String>, Int)] = [
            (\.departureDate, 10), (\.trainNumber, 16), (\.departureStation, 64),
            (\.departureTime, 5), (\.arrivalStation, 64), (\.arrivalDate, 10),
            (\.arrivalTime, 5), (\.carriage, 16), (\.seat, 32), (\.seatClass, 32),
            (\.gate, 32), (\.passenger, 64)
        ]
        for (key, limit) in limits {
            let text = result[keyPath: key].trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= limit, !text.contains("\u{FFFD}"),
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PickupStorageError.invalidData("火车票字段过长或含有无效字符，请核对原文。")
            }
            result[keyPath: key] = text
        }
        guard !result.trainNumber.isEmpty, !result.departureStation.isEmpty,
              !result.arrivalStation.isEmpty, result.departure != nil else {
            throw PickupStorageError.invalidData("请填写有效的出发日期、车次、出发站、出发时间和到达站。")
        }
        guard result.trainNumber.range(of: #"^[A-Za-z]?[0-9]{1,5}$"#, options: .regularExpression) != nil else {
            throw PickupStorageError.invalidData("车次格式无效，请核对原文。")
        }
        guard result.arrivalDate.isEmpty == result.arrivalTime.isEmpty else {
            throw PickupStorageError.invalidData("到达日期与时间须同时填写或同时留空。")
        }
        if !result.arrivalDate.isEmpty {
            guard let arrival = result.arrival, let departure = result.departure, arrival >= departure else {
                throw PickupStorageError.invalidData("到达日期时间无效或早于出发时间。")
            }
        }
        return result
    }

    // Operational duplicate identity; gate/class/arrival corrections do not create a new ticket.
    var duplicateIdentity: [String] {
        [departureDate, departureTime, trainNumber, departureStation, arrivalStation, passenger, carriage, seat]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

struct TrainTicketDisplayWindow: Codable, Equatable {
    var enabled: Bool = true
    var startsAt: Date? = nil
    var endsAt: Date? = nil
}

struct TrainTicket: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var fields: TrainTicketFields
    var isArchived: Bool = false
    var isEnded: Bool = false
    var keepVisible: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var displayWindow: TrainTicketDisplayWindow? = nil

    var widgetStartsAt: Date? {
        if let displayWindow { return displayWindow.startsAt }
        guard let departure = fields.departure else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.startOfDay(for: departure)
    }
    var widgetEndsAt: Date? { displayWindow?.endsAt ?? fields.arrival }

    // Nil is a legacy shape, not permission to display indefinitely.
    func validatedDisplayWindow() throws {
        guard let window = displayWindow else { return }
        guard [window.startsAt, window.endsAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw PickupStorageError.invalidData("展示窗口日期必须有效。")
        }
        guard window.enabled else { return }
        guard let start = window.startsAt, let end = widgetEndsAt,
              end.timeIntervalSinceReferenceDate.isFinite, end > start else {
            throw PickupStorageError.invalidData("请明确展示开始时间，并提供晚于开始的结束时间或到达时间。")
        }
    }

    func isWidgetVisible(at now: Date) -> Bool {
        guard !isArchived, !isEnded, displayWindow?.enabled != false,
              now.timeIntervalSinceReferenceDate.isFinite,
              let start = widgetStartsAt, let end = widgetEndsAt,
              start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
              end > start else { return false }
        return start <= now && now < end
    }
}

enum TrainWidgetSlot: String, Codable, CaseIterable, Identifiable {
    case a, b
    var id: String { rawValue }
    var kind: String { self == .a ? "ParcelKeeperTrainA" : "ParcelKeeperTrainB" }
    var title: String { self == .a ? "火车票 A" : "火车票 B" }
}

enum TrainWidgetMode: String, Codable { case automatic, fixed }

struct TrainWidgetBinding: Codable, Equatable {
    var slot: TrainWidgetSlot
    var mode: TrainWidgetMode
    var ticketID: UUID? = nil
    var browsingTicketID: UUID? = nil
}

enum TrainTicketSelection {
    static func binding(for slot: TrainWidgetSlot, in bindings: [TrainWidgetBinding]) -> TrainWidgetBinding {
        bindings.first { $0.slot == slot } ?? TrainWidgetBinding(slot: slot, mode: slot == .a ? .automatic : .fixed)
    }
    static func eligibleTickets(in tickets: [TrainTicket], now: Date) -> [TrainTicket] {
        tickets.filter { $0.isWidgetVisible(at: now) }.sorted {
            let left = $0.fields.departure ?? .distantFuture
            let right = $1.fields.departure ?? .distantFuture
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
    }

    static func ticket(in tickets: [TrainTicket], binding: TrainWidgetBinding, now: Date) -> TrainTicket? {
        let eligible = eligibleTickets(in: tickets, now: now)
        if binding.mode == .fixed { return eligible.first { $0.id == binding.ticketID } }
        if let browsing = eligible.first(where: { $0.id == binding.browsingTicketID }) { return browsing }
        return eligible.first
    }

    // Includes now; at most 39 future boundaries within the next 24 hours.
    // The widget owns refresh policy if more boundaries remain after this prefix.
    static func timelineDates(in tickets: [TrainTicket], now: Date) -> [Date] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return [now] }
        let horizon = now.addingTimeInterval(24 * 60 * 60)
        let boundaries = tickets.flatMap { ticket -> [Date] in
            guard !ticket.isArchived, !ticket.isEnded, ticket.displayWindow?.enabled != false,
                  let start = ticket.widgetStartsAt, let end = ticket.widgetEndsAt,
                  start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                  end > start else { return [] }
            return [start, end].filter { $0 > now && $0 <= horizon }
        }
        return [now] + Array(Set(boundaries).sorted().prefix(39))
    }
}
