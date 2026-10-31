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

struct TrainTicket: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var fields: TrainTicketFields
    var isArchived: Bool = false
    var isEnded: Bool = false
    var keepVisible: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
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
}

enum TrainTicketSelection {
    static func binding(for slot: TrainWidgetSlot, in bindings: [TrainWidgetBinding]) -> TrainWidgetBinding {
        bindings.first { $0.slot == slot } ?? TrainWidgetBinding(slot: slot, mode: slot == .a ? .automatic : .fixed)
    }
    static func ticket(in tickets: [TrainTicket], binding: TrainWidgetBinding, now: Date) -> TrainTicket? {
        let active = tickets.filter { !$0.isArchived && !$0.isEnded }
        if binding.mode == .fixed { return active.first { $0.id == binding.ticketID } }
        return active.filter { $0.keepVisible || ($0.fields.arrival.map { $0 > now } ?? true) }.sorted {
            let left = $0.fields.departure ?? .distantFuture
            let right = $1.fields.departure ?? .distantFuture
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }.first
    }
}
