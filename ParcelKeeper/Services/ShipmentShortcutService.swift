import Foundation
import WidgetKit

struct ShipmentShortcutInput: Equatable {
    var trackingNumber: String
    var carrierName: String?
    var logisticsInfo: String?
    var status: ShipmentStatus?
    var logisticsTime: Date?
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
        // Negation/awaiting collection comes before positive delivery phrases.
        if ["未签收", "尚未签收", "待签收", "等待领取", "待取件", "待领取", "尚未领取", "未领取", "等待取件", "请取件", "已放驿站", "已放入快递柜", "已到驿站"].contains(where: text.contains) { return .readyForPickup }
        if ["未取件", "未完成", "未收货"].contains(where: text.contains) { return nil }
        if ["已签收", "本人签收", "签收成功", "已领取", "已取件", "已收货", "已完成"].contains(where: text.contains) { return .delivered }
        if ["异常", "拒收", "退回", "滞留"].contains(where: text.contains) { return .exception }
        if ["派送中", "配送中", "正在派送", "正在配送"].contains(where: text.contains) { return .outForDelivery }
        if ["运输中", "转运", "已发出", "已揽收", "已到达", "正在发往"].contains(where: text.contains) { return .inTransit }
        return nil
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
        let pattern = #"(?:运单号|物流单号|快递单号|单号|trackingNumber)\s*[：:=]?\s*[\"']?([A-Za-z0-9]{8,28})(?![A-Za-z0-9])"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let labeled = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return try? number(String(text[range]))
        } ?? []
        // Do not let an extra plausible tracking token disappear merely because
        // one other token is labeled. Multiple parcels must never share fields.
        let detected = CarrierDetector.extractTrackingNumbers(from: text).filter { (try? number($0)) != nil }
        return Array(Set(labeled + detected)).sorted()
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
            let info = field(["logisticsInfo", "物流信息", "最新物流"])
            let stateText = field(["status", "物流状态", "状态"])
            let timeText = field(["logisticsTime", "物流时间"])
            let time = timeText.flatMap(date)
            if timeText != nil && time == nil { throw ShipmentShortcutError.invalidText }
            if let expected = stateText.flatMap(status), let observed = info.flatMap(status), expected != observed { throw ShipmentShortcutError.statusConflict }
            return ShipmentShortcutInput(trackingNumber: id, carrierName: field(["carrierName", "快递服务商", "快递公司"]), logisticsInfo: info,
                status: stateText.flatMap(status) ?? info.flatMap(status), logisticsTime: time)
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let timeRegex = try NSRegularExpression(pattern: #"(\d{4}[-/]\d{2}[-/]\d{2}[ T]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:\d{2})?)"#)
        var events: [(Date, String)] = []
        var undatedStates: [(ShipmentStatus, String)] = []
        for line in lines {
            let matches = timeRegex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard matches.count <= 1 else { throw ShipmentShortcutError.ambiguous }
            if let match = matches.first, let range = Range(match.range(at: 1), in: line) {
                guard let time = date(String(line[range])) else { throw ShipmentShortcutError.invalidText }
                let description = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "：:|-")))
                guard !description.isEmpty else { throw ShipmentShortcutError.ambiguous }
                events.append((time, description))
            } else if let state = status(line) { undatedStates.append((state, line)) }
        }
        let carrier = CarrierDetector.carrierMentioned(in: text)?.name
        if !events.isEmpty {
            let sorted = events.sorted { $0.0 > $1.0 }
            let newest = sorted[0]
            if sorted.dropFirst().contains(where: { $0.0 == newest.0 && $0.1 != newest.1 }) { throw ShipmentShortcutError.ambiguous }
            let state = status(newest.1)
            // Conflicting undated summaries cannot be ordered against events.
            if undatedStates.contains(where: { $0.0 != state }) { throw ShipmentShortcutError.ambiguous }
            return .init(trackingNumber: id, carrierName: carrier, logisticsInfo: newest.1, status: state, logisticsTime: newest.0)
        }
        let states = Set(undatedStates.map { $0.0.rawValue })
        guard states.count <= 1 else { throw ShipmentShortcutError.ambiguous }
        let info = undatedStates.first?.1 ?? lines.first(where: { $0.hasPrefix("物流信息") || $0.hasPrefix("最新物流") })
        return .init(trackingNumber: id, carrierName: carrier, logisticsInfo: info, status: undatedStates.first?.0, logisticsTime: nil)
    }
}

struct ShipmentShortcutService {
    let store: SharedPickupStore
    var reloadWidgets: () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    static func live() throws -> ShipmentShortcutService {
        return try ShipmentShortcutService(store: SharedPickupStore(appGroupID: nil, accessMode: .existingSharedData))
    }
    func validate(_ input: ShipmentShortcutInput) throws -> ShipmentShortcutInput {
        var value = input
        value.trackingNumber = try ShipmentShortcutParser.number(input.trackingNumber)
        func nonempty(_ text: String?) -> String? { text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text?.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        value.carrierName = nonempty(value.carrierName)
        value.logisticsInfo = nonempty(value.logisticsInfo)
        guard (value.carrierName?.count ?? 0) <= 100, (value.logisticsInfo?.count ?? 0) <= 10000 else { throw ShipmentShortcutError.invalidText }
        if value.status == nil { value.status = value.logisticsInfo.flatMap(ShipmentShortcutParser.status) }
        else if let inferred = value.logisticsInfo.flatMap(ShipmentShortcutParser.status), inferred != value.status {
            throw ShipmentShortcutError.statusConflict
        }
        return value
    }
    /// The match and all writes occur under the existing store transaction.
    @discardableResult func upsert(_ input: ShipmentShortcutInput) throws -> Bool {
        let value = try validate(input)
        let inserted = try store.transaction { data -> Bool in
            let matches = data.shipments.indices.filter { CarrierDetector.sanitize(data.shipments[$0].trackingNumber) == value.trackingNumber }
            guard matches.count <= 1 else { throw ShipmentShortcutError.ambiguous }
            let now = Date()
            let index: Int
            let isNew = matches.isEmpty
            if let match = matches.first { index = match }
            else {
                let detection = CarrierDetector.detect(value.trackingNumber)
                let carrier = detection.confidence >= 0.9 ? detection.carrier : CarrierDetector.unknown
                data.shipments.append(Shipment(trackingNumber: value.trackingNumber, carrierName: carrier.name, carrierCode: carrier.code))
                index = data.shipments.count - 1
            }
            var shipment = data.shipments[index]
            if let old = shipment.logisticsTime, let new = value.logisticsTime, new < old { throw ShipmentShortcutError.olderUpdate }
            // An undated update cannot supersede an event with known time.
            if shipment.logisticsTime != nil && value.logisticsTime == nil && (value.logisticsInfo != nil || value.status != nil) { throw ShipmentShortcutError.statusConflict }
            if [.delivered, .archived].contains(shipment.status), let state = value.status, state != .delivered && state != shipment.status { throw ShipmentShortcutError.statusConflict }
            if let name = value.carrierName {
                shipment.carrierName = name
                shipment.carrierCode = CarrierDetector.carrierMentioned(in: name)?.code ?? CarrierDetector.unknown.code
            }
            if let info = value.logisticsInfo { shipment.logisticsInfo = info }
            if let time = value.logisticsTime { shipment.logisticsTime = time }
            if let state = value.status, shipment.status != .archived { shipment.status = state }
            shipment.updatedAt = now
            data.shipments[index] = shipment
            if let linked = data.records.firstIndex(where: { $0.shipmentID == shipment.id }) {
                if value.status == .delivered { data.records[linked].isCompleted = true }
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
