import Foundation
import WidgetKit

struct ShipmentShortcutInput: Equatable {
    var trackingNumber: String
    var carrierName: String?
    var logisticsInfo: String?
    var status: ShipmentStatus?
    var logisticsTime: Date?
    var queryInfo: String? = nil
    // Set only by labeled local parsing, not inferred from event prose.
    var hasExplicitCurrentStatus = false
}

enum ShipmentShortcutError: LocalizedError {
    case invalidNumber, ambiguous, missingNumber, olderUpdate, statusConflict, invalidText
    var errorDescription: String? {
        switch self {
        case .invalidNumber: return "运单号格式无效；请只传入完整单号。"
        case .ambiguous: return "文本包含多个单号或无法确定最新物流，请分别传入每票快递的最新信息。"
        case .missingNumber: return "未识别到唯一运单号。"
        case .olderUpdate: return "传入的物流时间早于现有记录，未覆盖。"
        case .statusConflict: return "已完成快递收到未完成状态，未自动恢复；请在 App 核对。"
        case .invalidText: return "物流文本为空、过长或时间格式无效。"
        }
    }
}

/// Consumes supplied logistics, never queries a tracking provider.
enum ShipmentShortcutParser {
    static func number(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.range(of: #"^[A-Z0-9]{8,28}$"#, options: .regularExpression) != nil,
              value.filter(\.isNumber).count >= 6,
              value.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) == nil else { throw ShipmentShortcutError.invalidNumber }
        return value
    }
    static func status(_ text: String) -> ShipmentStatus? {
        // Classify ONE event, never a concatenated history. A station/cabinet
        // receipt is custody, not evidence that the recipient collected it.
        let text = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        if ["异常", "拒收", "退回", "滞留"].contains(where: text.contains) { return .exception }
        if ["未签收", "尚未签收", "待签收", "等待领取", "待取件", "待领取", "尚未领取", "未领取", "等待取件", "请取件"].contains(where: text.contains) { return .readyForPickup }
        if ["非本人签收", "非收件人签收", "未经本人签收", "未经收件人签收", "未由本人签收", "未由收件人签收", "不是本人签收", "不是收件人签收"].contains(where: text.contains) { return .readyForPickup }
        if ["未取件", "未完成", "未收货"].contains(where: text.contains) {
            return ["驿站", "快递柜", "丰巢", "代收点", "代收", "取件码"].contains(where: text.contains) ? .readyForPickup : nil
        }
        if text.range(of: #"(?:请|请尽快|请凭|请使用|请您)[^，。；;！!？?\n]*完成取件"#, options: .regularExpression) != nil { return .readyForPickup }
        if ["本人签收", "收件人签收", "已领取", "已取件", "已收货", "完成取件"].contains(where: text.contains) { return .delivered }
        if ["驿站", "快递柜", "丰巢", "代收点", "代收", "取件码"].contains(where: text.contains) { return .readyForPickup }
        if ["已签收", "签收成功", "已完成"].contains(where: text.contains) { return .delivered }
        if ["派送中", "配送中", "正在派送", "正在配送", "快递员派送"].contains(where: text.contains) { return .outForDelivery }
        if ["运输中", "转运", "已发出", "已揽收", "已到达", "正在发往"].contains(where: text.contains) { return .inTransit }
        return nil
    }
    /// An unclassified denial is not permission for an explicit delivered value.
    static func deniesCompletion(_ raw: String) -> Bool {
        let text = raw.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? raw
        return ["未取件", "未完成", "未收货", "未签收", "尚未签收", "待签收", "未领取", "尚未领取", "非本人签收", "非收件人签收", "未经本人签收", "未经收件人签收", "未由本人签收", "未由收件人签收", "不是本人签收", "不是收件人签收"].contains(where: text.contains)
    }
    static func date(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: raw) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: raw) { return value }
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 8 * 3600); f.dateFormat = format; f.isLenient = false
            if let value = f.date(from: raw) { return value }
        }
        return nil
    }
    static func numbers(in text: String) -> [String] {
        // Share one boundary/field policy with smart import. No confidence
        // cutoff or default 12-result limit may hide an ambiguous second parcel.
        let detected = CarrierDetector.extractTrackingNumbers(from: text, limit: Int.max)
            .filter { (try? number($0)) != nil }
        return Array(Set(detected)).sorted()
    }
    static func parse(_ raw: String) throws -> ShipmentShortcutInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 10000 else { throw ShipmentShortcutError.invalidText }
        let object: [String: Any]?
        if let bytes = text.data(using: .utf8) {
            object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        } else { object = nil }
        let ids: [String]
        if let object, let rawNumber = (object["trackingNumber"] ?? object["快递单号"] ?? object["单号"]) as? String {
            ids = [try number(rawNumber)]
            let others = numbers(in: text).filter { $0 != ids[0] }
            guard others.isEmpty else { throw ShipmentShortcutError.ambiguous }
        } else { ids = numbers(in: text) }
        guard ids.count <= 1 else { throw ShipmentShortcutError.ambiguous }
        guard let id = ids.first else { throw ShipmentShortcutError.missingNumber }
        // JSON is the preferred minis contract. Missing fields remain absent.
        if let object {
            func field(_ names: [String]) -> String? {
                for name in names { if let value = object[name] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) } }
                return nil
            }
            let suppliedInfo = field(["logisticsInfo", "物流信息", "最新物流"])
            let event = try suppliedInfo.map { try latestEvent(in: $0) }
            let info = event?.info ?? suppliedInfo
            let stateText = field(["status", "物流状态", "状态"])
            let timeText = field(["logisticsTime", "物流时间"])
            let suppliedTime = timeText.flatMap(date)
            if timeText != nil && suppliedTime == nil { throw ShipmentShortcutError.invalidText }
            if let eventTime = event?.time, let suppliedTime, eventTime != suppliedTime { throw ShipmentShortcutError.ambiguous }
            let time = event?.time ?? suppliedTime
            if stateText.flatMap(status) == .delivered, let info, deniesCompletion(info) { throw ShipmentShortcutError.statusConflict }
            if let expected = stateText.flatMap(status), let observed = info.flatMap(status), expected != observed { throw ShipmentShortcutError.statusConflict }
            return ShipmentShortcutInput(trackingNumber: id, carrierName: field(["carrierName", "快递服务商", "快递公司"]), logisticsInfo: info,
                status: stateText.flatMap(status) ?? info.flatMap(status), logisticsTime: time)
        }
        if let labeled = try labeledResult(in: text, trackingNumber: id) { return labeled }
        let event = try latestEvent(in: text)
        return .init(trackingNumber: id, carrierName: CarrierDetector.carrierMentioned(in: text)?.name,
                     logisticsInfo: event.info, status: event.state, logisticsTime: event.time)
    }

    /// Split labeled query output before interpreting its event. Labels, emoji,
    /// and source metadata are not part of the persisted event description.
    private static func labeledResult(in text: String, trackingNumber: String) throws -> ShipmentShortcutInput? {
        let regex = try NSRegularExpression(pattern: #"(快递单号|快递公司|当前状态|最新时间|最新进展|查询来源)\s*[：:]"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.contains(where: { match in
            Range(match.range(at: 1), in: text).map { text[$0] == "最新进展" || text[$0] == "当前状态" } ?? false
        }) else { return nil }
        var fields: [String: String] = [:]
        let decorations = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "📦🚚📍🕒🔍\u{FE0F}"))
        for (index, match) in matches.enumerated() {
            guard let keyRange = Range(match.range(at: 1), in: text) else { throw ShipmentShortcutError.invalidText }
            let key = String(text[keyRange])
            guard fields[key] == nil else { throw ShipmentShortcutError.ambiguous }
            let end = index + 1 < matches.count ? matches[index + 1].range.location : (text as NSString).length
            let range = NSRange(location: NSMaxRange(match.range), length: end - NSMaxRange(match.range))
            guard let valueRange = Range(range, in: text) else { throw ShipmentShortcutError.invalidText }
            fields[key] = String(text[valueRange]).trimmingCharacters(in: decorations)
        }
        func value(_ key: String) -> String? { fields[key].flatMap { $0.isEmpty ? nil : $0 } }
        let info = value("最新进展")
        let event = try info.map { try latestEvent(in: $0) }
        let state = value("当前状态").flatMap(status)
        let observed = event?.state
        // The explicitly labeled current state wins over event wording.
        // Do not search the full query/history for a competing status.
        let suppliedTime = value("最新时间")
        let time = suppliedTime.flatMap(date)
        if suppliedTime != nil && time == nil { throw ShipmentShortcutError.invalidText }
        if let time, let eventTime = event?.time, time != eventTime { throw ShipmentShortcutError.ambiguous }
        return .init(trackingNumber: trackingNumber, carrierName: value("快递公司"),
                     logisticsInfo: event?.info ?? info, status: state ?? observed, logisticsTime: event?.time ?? time,
                     hasExplicitCurrentStatus: state != nil)
    }

    /// Local text import only. Refuses unorderable histories.
    static func latestEvent(in text: String) throws -> (info: String?, state: ShipmentStatus?, time: Date?) {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let timeRegex = try NSRegularExpression(pattern: #"(\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})?)"#)
        var events: [(Date, String)] = []
        var undatedStates: [(ShipmentStatus, String)] = []
        for line in lines {
            let matches = timeRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard matches.count <= 1 else { throw ShipmentShortcutError.ambiguous }
            if let match = matches.first, let range = Range(match.range(at: 1), in: line) {
                guard let time = date(String(line[range])) else { throw ShipmentShortcutError.invalidText }
                // Some providers put the event before its timestamp. Preserve
                // both sides; dropping the prefix could resurrect an old receipt.
                let description = (String(line[..<range.lowerBound]) + " " + String(line[range.upperBound...]))
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:|-")))
                // A standalone query timestamp is page metadata, not a parcel
                // event. Match only its complete label so real event descriptions
                // mentioning query time are preserved, regardless of row order.
                if description.range(of: #"^查[询詢][时時][间間][\s：:|\-]*$"#, options: .regularExpression) != nil { continue }
                guard !description.isEmpty else { throw ShipmentShortcutError.ambiguous }
                events.append((time, description))
            } else {
                // A carrier/station title containing only parcel metadata is
                // not a logistics event. Keep genuine undated summaries intact.
                let metadata = line.replacingOccurrences(of: #"(?:运单号|運單號|物流单号|物流單號|快递单号|快遞單號|单号|單號|trackingNumber)\s*[：:=]?\s*[A-Za-z0-9]{8,28}(?![A-Za-z0-9_－-])"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: #"(?:菜鸟驿站|菜鳥驛站|驿站|驛站|丰巢|豐巢|快递柜|快遞櫃|圆通速递|顺丰速运|快递|物流|[\s：:|,，-])+"#, with: "", options: .regularExpression)
                let isParcelTitle = metadata.isEmpty && !numbers(in: line).isEmpty
                if !isParcelTitle, let state = status(line) { undatedStates.append((state, line)) }
            }
        }
        if !events.isEmpty {
            let sorted = events.sorted { $0.0 > $1.0 }
            let newest = sorted[0]
            if sorted.dropFirst().contains(where: { $0.0 == newest.0 && $0.1 != newest.1 }) { throw ShipmentShortcutError.ambiguous }
            let state = status(newest.1)
            // Conflicting undated summaries cannot be ordered against events.
            if undatedStates.contains(where: { $0.0 != state }) { throw ShipmentShortcutError.ambiguous }
            return (newest.1, state, newest.0)
        }
        let states = Set(undatedStates.map { $0.0.rawValue })
        guard states.count <= 1 else { throw ShipmentShortcutError.ambiguous }
        let info = undatedStates.first?.1 ?? lines.first(where: { $0.hasPrefix("物流信息") || $0.hasPrefix("最新物流") })
        // Multiple undated descriptions cannot establish which one is latest,
        // even when their states happen to match.
        guard Set(undatedStates.map { $0.1 }).count <= 1 else { throw ShipmentShortcutError.ambiguous }
        return (info, undatedStates.first?.0, nil)
    }
}

struct ShipmentShortcutService {
    let store: SharedPickupStore
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    static func live() throws -> ShipmentShortcutService {
        return try ShipmentShortcutService(store: SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData))
    }
    func validate(_ input: ShipmentShortcutInput, inferLogistics: Bool = true) throws -> ShipmentShortcutInput {
        var value = input
        value.trackingNumber = try ShipmentShortcutParser.number(input.trackingNumber)
        func nonempty(_ text: String?) -> String? { text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text?.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        value.carrierName = nonempty(value.carrierName)
        value.logisticsInfo = nonempty(value.logisticsInfo)
        guard (value.queryInfo?.count ?? 0) <= 10000 else { throw ShipmentShortcutError.invalidText }
        if value.queryInfo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { value.queryInfo = nil }
        guard (value.carrierName?.count ?? 0) <= 100, (value.logisticsInfo?.count ?? 0) <= 10000 else { throw ShipmentShortcutError.invalidText }
        if let info = value.logisticsInfo {
            let others = ShipmentShortcutParser.numbers(in: info).filter { $0 != value.trackingNumber }
            guard others.isEmpty else { throw ShipmentShortcutError.ambiguous }
            guard inferLogistics else { return value }
            let event = try ShipmentShortcutParser.latestEvent(in: info)
            if let time = event.time {
                if let supplied = value.logisticsTime, supplied != time { throw ShipmentShortcutError.ambiguous }
                value.logisticsTime = time
                value.logisticsInfo = event.info
            }
            let inferred = event.state
            let selectedInfo = event.info ?? info
            if !value.hasExplicitCurrentStatus {
                if value.status == .delivered && ShipmentShortcutParser.deniesCompletion(selectedInfo) { throw ShipmentShortcutError.statusConflict }
                if let explicit = value.status, let inferred, explicit != inferred { throw ShipmentShortcutError.statusConflict }
            }
            if value.status == nil { value.status = inferred }
        }
        return value
    }
    /// The match and all writes occur under the existing store transaction.
    @discardableResult func upsert(_ input: ShipmentShortcutInput, inferLogistics: Bool = true) throws -> Bool {
        let value = try validate(input, inferLogistics: inferLogistics)
        let inserted = try store.transaction { data -> Bool in
            let matches = data.shipments.indices.filter { CarrierDetector.sanitize(data.shipments[$0].trackingNumber) == value.trackingNumber }
            guard matches.count <= 1 else { throw ShipmentShortcutError.ambiguous }
            let now = Date()
            let index: Int
            let isNew = matches.isEmpty
            if let match = matches.first { index = match }
            else {
                let detection = inferLogistics ? CarrierDetector.detect(value.trackingNumber) : nil
                let carrier = detection.map { $0.confidence >= 0.9 ? $0.carrier : CarrierDetector.unknown } ?? CarrierDetector.unknown
                data.shipments.append(Shipment(trackingNumber: value.trackingNumber, carrierName: carrier.name, carrierCode: carrier.code))
                index = data.shipments.count - 1
            }
            var shipment = data.shipments[index]
            let previousStatus = shipment.status
            if let old = shipment.logisticsTime, let new = value.logisticsTime, new < old { throw ShipmentShortcutError.olderUpdate }
            // An undated update cannot supersede an event with known time.
            if shipment.logisticsTime != nil && value.logisticsTime == nil && (value.logisticsInfo != nil || value.status != nil) { throw ShipmentShortcutError.statusConflict }
            if [.delivered, .archived].contains(shipment.status), let state = value.status, state != .delivered && state != shipment.status { throw ShipmentShortcutError.statusConflict }
            if let name = value.carrierName {
                let code = CarrierDetector.carrierMentioned(in: name)?.code ?? CarrierDetector.unknown.code
                if shipment.carrierCode != code { shipment.uapiCarrierCode = nil }
                shipment.carrierName = name
                shipment.carrierCode = code
            }
            if let info = value.logisticsInfo { shipment.logisticsInfo = info }
            if let query = value.queryInfo { shipment.queryInfo = query }
            if let time = value.logisticsTime { shipment.logisticsTime = time }
            if let state = value.status, shipment.status != .archived { shipment.status = state }
            shipment.updatedAt = now
            data.shipments[index] = shipment
            if let linked = data.records.firstIndex(where: { $0.shipmentID == shipment.id }) {
                if shipment.status != previousStatus {
                    let becomesCompleted = shipment.status == .delivered || shipment.status == .archived
                    let record = data.records[linked]
                    let code = record.code.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Only a newly reopened pending code can introduce a duplicate.
                    // Preserve pre-existing pending duplicates from history/backups.
                    if record.isCompleted && !becomesCompleted && !code.isEmpty {
                        guard !data.records.contains(where: {
                            $0.id != record.id && $0.groupID == record.groupID && !$0.isCompleted &&
                            $0.code.trimmingCharacters(in: .whitespacesAndNewlines) == code
                        }) else { throw PickupStorageError.invalidData("此分组已有未完成的相同取码。") }
                    }
                    data.records[linked].isCompleted = becomesCompleted
                }
                data.records[linked].updatedAt = now
            } else {
                guard let group = data.expressGroupID, data.groups.contains(where: { $0.id == group }) else { throw PickupStorageError.invalidData("快递默认分组不可用") }
                var record = PickupRecord(groupID: group, code: shipment.pickupCode, source: shipment.note, createdAt: shipment.createdAt, updatedAt: now, shipmentID: shipment.id)
                record.isCompleted = shipment.status == .delivered || shipment.status == .archived
                data.records.append(record)
            }
            return isNew
        }
        reloadWidgets()
        return inserted
    }
}
