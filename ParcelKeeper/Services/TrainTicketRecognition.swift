import Foundation

enum TrainTicketRecognitionError: Error, LocalizedError {
    case unreliable, ambiguous, incomplete, duplicate
    var errorDescription: String? {
        switch self {
        case .unreliable: return "未找到可靠的单张火车票信息，请在 App 中手动填写。"
        case .ambiguous: return "存在多张车票或多位乘客，未保存；请每次只提供一张票。"
        case .incomplete: return "乘车日期（含年份）、车次、出发站、发车时间和到达站必须完整，请打开 App 补齐并确认。"
        case .duplicate: return "该车票已存在，未重复添加或覆盖。"
        }
    }
}

enum TrainTicketRecognition {
    static func recognize(_ text: String, useAI: Bool,
                          ai: (String) async throws -> TrainTicketFields) async throws -> TrainTicketFields {
        if useAI {
            try rejectAmbiguity(text)
            let fields = try await ai(text)
            guard !hasMultiplePassengers(fields.passenger) else { throw TrainTicketRecognitionError.ambiguous }
            return fields
        }
        return try parse(text)
    }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
    // Split only explicit field envelopes, not spaces inside values (John Smith).
    private static let nonTravelTimeNames = "(?:下单|订单|支付|付款|出票|购票|查询|生成)(?:日期|时间)?"
    private static let fieldNames = nonTravelTimeNames + "|出发日期|乘车日期|到达日期|车次|出发站|始发站|到达站|终到站|发车时间|出发时间|到达时间|车厢|座位|席别|座席|检票口|乘车人|旅客|姓名|身份证号?|证件号码?|证件类型|手机号?|电话号码?|订单号?|下单时间|下单日期|订单时间|订单日期|支付时间|支付日期|付款时间|付款日期|出票时间|出票日期|购票时间|购票日期|查询时间|查询日期|生成时间|生成日期"
    private static func fieldLines(_ text: String) -> String {
        text.replacingOccurrences(of: "(?:" + fieldNames + ")\\s*[:：]", with: "\n$0", options: .regularExpression)
    }
    static func hasMultiplePassengers(_ value: String) -> Bool {
        value.range(of: #"[、/]"#, options: .regularExpression) != nil
            || value.range(of: #"[\p{Han}][\p{Han}*＊·]{0,15}[\s,，;；]+[\p{Han}][\p{Han}*＊·]{0,15}"#, options: .regularExpression) != nil
    }
    private static let singleValueFieldGroups = [
        "出发日期|乘车日期", "到达日期", "车次", "出发站|始发站", "到达站|终到站",
        "发车时间|出发时间", "到达时间", "车厢", "座位", "席别|座席", "检票口", "乘车人|旅客|姓名"
    ]

    // Structural multiplicity protection, not a local semantic interpretation of AI fields.
    static func rejectAmbiguity(_ text: String) throws {
        let segmented = fieldLines(text)
        // Count labels, not distinct values: repeated equal fields may still be two tickets.
        // Synonyms belong to the same single-value field and must not bypass this guard.
        for names in singleValueFieldGroups {
            if matches("(?:^|[\\n；;])\\s*(?:" + names + ")\\s*[:：]", segmented).count > 1 {
                throw TrainTicketRecognitionError.ambiguous
            }
        }
        let trains = matches(#"(?i)(?<![A-Z0-9])[GDCZTKYLS]\d{1,5}(?![A-Z0-9])"#, text)
        let trainLabels = matches(#"车次\s*[:：]"#, text)
        let passengers = matches(#"(?:乘车人|旅客|姓名)[ \t]*[:：]?[ \t]*([^\n]+)"#, fieldLines(text))
        let departureLabels = matches(#"(?:出发日期|乘车日期)\s*[:：]"#, text)
        let seatGroups = matches(#"\d{1,2}车\s*\d{1,3}[A-Fa-f]?号"#, text)
        let passengerList = passengers.contains { hasMultiplePassengers($0[1]) }
        if trains.count > 1 || trainLabels.count > 1 ||
            passengers.count > 1 || departureLabels.count > 1 || seatGroups.count > 1 || passengerList {
            throw TrainTicketRecognitionError.ambiguous
        }
    }
    // Order/payment timestamps are not travel evidence. Never borrow their year.
    static func travelEvidence(_ text: String) -> String {
        // Segment inline labels first: an order timestamp must not discard the
        // adjacent journey, nor contribute its year/time to AI evidence checks.
        fieldLines(text).components(separatedBy: .newlines).filter {
            $0.range(of: "^\\s*" + nonTravelTimeNames + "\\s*[:：]", options: .regularExpression) == nil
        }.joined(separator: "\n")
    }
    static func normalizedDate(_ value: String) -> String? {
        let m = matches(#"^\s*(\d{4})[-/年](\d{1,2})[-/月](\d{1,2})日?\s*$"#, value)
        guard let v = m.first, let year = Int(v[1]), let month = Int(v[2]), let day = Int(v[3]) else { return nil }
        let result = String(format: "%04d-%02d-%02d", year, month, day)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: result), formatter.string(from: date) == result else { return nil }
        return result
    }
    static func normalizedTime(_ value: String) -> String? {
        guard let v = matches(#"^(\d{1,2})[:：](\d{2})$"#, value).first,
              let h = Int(v[1]), let m = Int(v[2]), h < 24, m < 60 else { return nil }
        return String(format: "%02d:%02d", h, m)
    }
    static func parse(_ text: String) throws -> TrainTicketFields {
        guard !text.isEmpty, text.count <= 10000 else { throw TrainTicketRecognitionError.unreliable }
        try rejectAmbiguity(text)
        let evidence = travelEvidence(text)
        func label(_ names: String) -> String {
            matches("(?:^|[\\n；;])\\s*(?:" + names + ")\\s*[:：]\\s*([^\\n；;]*)", evidence).first?[1].trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var f = TrainTicketFields()
        f.departureDate = normalizedDate(label("出发日期|乘车日期")) ?? ""
        f.arrivalDate = normalizedDate(label("到达日期")) ?? ""
        f.trainNumber = label("车次")
        if f.trainNumber.isEmpty { f.trainNumber = matches(#"(?i)(?<![A-Z0-9])[GDCZTKYLS]\d{1,5}(?![A-Z0-9])"#, evidence).first?[0] ?? "" }
        f.departureStation = label("出发站|始发站")
        f.arrivalStation = label("到达站|终到站")
        f.departureTime = normalizedTime(label("发车时间|出发时间")) ?? ""
        f.arrivalTime = normalizedTime(label("到达时间")) ?? ""
        f.carriage = label("车厢"); f.seat = label("座位"); f.seatClass = label("席别|座席")
        f.gate = label("检票口"); f.passenger = label("乘车人|旅客|姓名")
        let stations = matches(#"(?m)^\s*([\p{Han}]{2,12})\s*(\d{1,2}[:：]\d{2})\s*$"#, evidence)
        if stations.count == 2 {
            if f.departureStation.isEmpty { f.departureStation = stations[0][1] }
            if f.departureTime.isEmpty { f.departureTime = normalizedTime(stations[0][2]) ?? "" }
            if f.arrivalStation.isEmpty { f.arrivalStation = stations[1][1] }
            if f.arrivalTime.isEmpty { f.arrivalTime = normalizedTime(stations[1][2]) ?? "" }
        } else if stations.count > 2 { throw TrainTicketRecognitionError.ambiguous }
        if f.departureDate.isEmpty {
            let dates = matches(#"(?m)^\s*(\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?)(?:\s*(?:周|星期)[一二三四五六日天])?\s*$"#, evidence)
            if dates.count == 1 { f.departureDate = normalizedDate(dates[0][1]) ?? "" }
        }
        if let v = matches(#"(\d{1,2})车\s*(\d{1,3}[A-Fa-f]?)号(上铺|中铺|下铺)?\s*(商务座|特等座|一等座|二等座|硬座|软座|硬卧|软卧|无座)?"#, evidence).first {
            if f.carriage.isEmpty { f.carriage = v[1] }
            if f.seat.isEmpty { f.seat = v[3].isEmpty ? v[2] : v[2] + "号" + v[3] }
            if f.seatClass.isEmpty { f.seatClass = v[4] }
        }
        if f.seatClass.isEmpty {
            let classes = Set(matches(#"商务座|特等座|一等座|二等座|硬座|软座|硬卧|软卧|无座"#, evidence).map { $0[0] })
            if classes.count == 1 { f.seatClass = classes.first ?? "" }
        }
        if f.seat.isEmpty, evidence.contains("无座") { f.seat = "无座" }
        if f.gate.isEmpty { f.gate = matches(#"检票口\s*[:：]?\s*([A-Za-z0-9、\-]+)"#, evidence).first?[1] ?? "" }
        if f.passenger.isEmpty { f.passenger = matches(#"乘车人\s*[:：]?\s*([\p{Han}*＊·]{1,30})"#, evidence).first?[1] ?? "" }
        guard !f.trainNumber.isEmpty, !f.departureStation.isEmpty, !f.arrivalStation.isEmpty, !f.departureTime.isEmpty,
              f.passenger.range(of: #"^[\p{L}*＊· .-]{0,40}$"#, options: .regularExpression) != nil else { throw TrainTicketRecognitionError.unreliable }
        // Drafts deliberately retain missing year/date; UI must ask the user, shortcuts validate strictly.
        return f
    }
}
