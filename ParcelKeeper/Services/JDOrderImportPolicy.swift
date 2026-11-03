import Foundation
import CoreFoundation

// Temporary JD-only import policy. No credentials or response bodies in reports.
struct JDOrderImportReport {
    var candidates: [MallCandidate] = []
    var scanned = 0
    var eligible = 0
    var withoutWaybill = 0
    var missingDate = 0
    var excluded = 0
    var outsideWindow = 0
    var limited = false

    var message: String {
        let numberedOrders = Set(candidates.map(\.orderID)).count
        let unreadDetails = max(0, eligible - numberedOrders - withoutWaybill)
        var text = "京东近30天购物订单测试（上海日历日，含今天及前29天、所有状态含已签收）：本次去重扫描\(scanned)笔，符合日期及购物筛选\(eligible)笔，找到\(candidates.count)个可选快递运单（\(numberedOrders)笔订单）；\(withoutWaybill)笔暂无真实运单，暂无法生成快递；\(missingDate)笔缺少可信下单日期未纳入；排除明确外卖/秒送/虚拟/服务\(excluded)笔，日期范围外\(outsideWindow)笔。"
        if unreadDetails > 0 { text += "另有\(unreadDetails)笔符合筛选订单尚未读完详情，不能视为无运单。" }
        if limited { text += "本次未读完订单列表或详情（分页/详情上限、时间预算或手机页范围限制），以上仅为已读取部分。" }
        return text
    }

    // Mutually exclusive categories, in this order: excluded, missing, outside, eligible.
    mutating func consider(submittedAt: Date?, excluded: Bool, policy: JDOrderImportPolicy) -> Bool {
        scanned += 1
        if excluded { self.excluded += 1; return false }
        guard let submittedAt else { missingDate += 1; return false }
        guard policy.contains(submittedAt) else { outsideWindow += 1; return false }
        eligible += 1
        return true
    }
    mutating func append(_ parcels: [MallWebDetail], orderID: String, title: String, url: String) throws {
        if parcels.isEmpty { withoutWaybill += 1 }
        for parcel in parcels {
            if let existing = candidates.first(where: { $0.trackingNumber == parcel.number }) {
                guard existing.orderID == orderID else { throw MallWebError.identityMismatch }
                continue
            }
            candidates.append(MallCandidate(trackingNumber: parcel.number, carrier: parcel.carrier,
                title: title, orderID: orderID, sourceURL: url))
        }
    }
    func logSummary(_ diagnostics: JDDiagnostics) {
        // Per-page events may exhaust the diagnostics anti-flood allowance;
        // write exactly one safe final aggregate without losing it behind that cap.
        diagnostics.log.record(.jdResponseAccepted, operation: diagnostics.operation,
            stage: diagnostics.trace.stage, counts: [.rows: scanned, .accepted: eligible,
            .rejected: excluded + missingDate + outsideWindow, .candidates: candidates.count])
    }
}

struct JDOrderImportPolicy {
    static let maxPages = 10
    static let maxDetails = 20
    let start: Date
    let end: Date
    init(now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.startOfDay(for: now)
        start = calendar.date(byAdding: .day, value: -29, to: today)!
        end = calendar.date(byAdding: .day, value: 1, to: today)!
    }
    // Half-open [today-29 days 00:00, tomorrow 00:00) in Shanghai; not now-720h.
    func contains(_ date: Date) -> Bool { date >= start && date < end }

    static func excluded(orderType: String, allVirtual: Bool, evidence: String) -> Bool {
        ["4", "69"].contains(orderType) || allVirtual ||
            ["外卖", "秒送", "虚拟", "服务"].contains(where: evidence.contains)
    }
    static func isTimeout(_ error: Error) -> Bool {
        (error as? MallWebError) == .timeout || (error as? URLError)?.code == .timedOut ||
            (error as? JDLoggedError)?.reason == .timeout
    }
    static func submittedDate(_ value: Any?) -> Date? {
        let raw: String
        if let string = value as? String { raw = string }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { raw = number.stringValue }
        else { return nil }
        guard raw.utf8.count <= 80 else { return nil }
        // Only the trusted order-submit field reaches here; never a logistics time.
        if raw.range(of: #"^(?:[0-9]{10}|[0-9]{13})$"#, options: .regularExpression) != nil,
           let value = Double(raw) {
            return Date(timeIntervalSince1970: raw.count == 13 ? value / 1000 : value)
        }
        let formats: [(String, String)] = [
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, "yyyy-MM-dd"),
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$"#, "yyyy-MM-dd HH:mm"),
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$"#, "yyyy-MM-dd HH:mm:ss"),
            (#"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$"#, "yyyy-MM-dd'T'HH:mm:ss")
        ]
        for (pattern, format) in formats where raw.range(of: pattern, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            formatter.isLenient = false; formatter.dateFormat = format
            guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
            return date
        }
        // Strict ISO with explicit offset. Reject normalized invalid dates by checking
        // the local calendar prefix independently before accepting the offset parser.
        if raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,3})?(?:Z|[+-](?:0[0-9]|1[0-4]):[0-5][0-9])$"#, options: .regularExpression) != nil {
            guard submittedDate(String(raw.prefix(19))) != nil else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = raw.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        return nil
    }
}
